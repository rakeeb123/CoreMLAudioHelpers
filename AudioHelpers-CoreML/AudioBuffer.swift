//
//  AudioBuffer.swift
//  AudioHelpers-CoreML
//
//  Created by Rakeeb Hossain on 2019-07-30.
//  Copyright © 2019 Rakeeb Hossain. All rights reserved.
//

import UIKit
import AVFoundation
import AudioToolbox
import CoreAudio

@objc protocol AURenderCallbackDelegate {
    func performRender(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       inTimeStamp: UnsafePointer<AudioTimeStamp>,
                       inBusNumber: UInt32,
                       inNumberFrames: UInt32,
                       ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus
}

struct EffectState {
    var rioUnit: AudioUnit?
    var asbd: AudioStreamBasicDescription?
    var sineFrequency: Float32?
    var sinePhase: Float32?
}

func InputModulatingRenderCallback(
    inRefCon:UnsafeMutableRawPointer,
    ioActionFlags:UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp:UnsafePointer<AudioTimeStamp>,
    inBusNumber:UInt32,
    inNumberFrames:UInt32,
    ioData:UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    
    let bufferSizeBytes = Int(inNumberFrames * 8)
    
    var bufferlist = AudioBufferList.allocate(maximumBuffers: 2)
    bufferlist[0].mNumberChannels = 1
    bufferlist[0].mDataByteSize = UInt32(bufferSizeBytes)
    bufferlist[0].mData = malloc(bufferSizeBytes)
    
    bufferlist[1].mNumberChannels = 1
    bufferlist[1].mDataByteSize = UInt32(bufferSizeBytes)
    bufferlist[1].mData = malloc(bufferSizeBytes)

    print(bufferlist[0])
    
    var effectState = inRefCon.assumingMemoryBound(to: EffectState.self)
    var status = AudioUnitRender(effectState.pointee.rioUnit!, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, bufferlist.unsafeMutablePointer)
    /*
    let delegate = unsafeBitCast(inRefCon, to: AURenderCallbackDelegate.self)
    status = delegate.performRender(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData!)
    if (status != 0) {
        
    }
     */
    return noErr
}

@objc (AudioBuffer)
class AudioBuffer: NSObject, AURenderCallbackDelegate {
    
    let dataPtr = UnsafeMutablePointer<EffectState>.allocate(capacity: 1)

    override init() {
        super.init()
        defer {dataPtr.deallocate()}
        dataPtr.initialize(to: EffectState())
        defer {dataPtr.deinitialize(count: 1)}

        let status = setupAudio(dataPtr)
        setupNotifications()
    }
    
    func setupAudio(_ dataPtr: UnsafeMutablePointer<EffectState>) -> Bool {
        // Init and setup recording session (AVAudioSession)
        var recordingSession: AVAudioSession = AVAudioSession.sharedInstance()
        var hardwareSampleRate: Double
        var error: OSStatus
        do {
            #if swift(>=4.2)
            try recordingSession.setCategory(AVAudioSession.Category.playAndRecord, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.defaultToSpeaker)
            if (!recordingSession.isInputAvailable) {
                print("Audio input not available")
                return false
            }
            hardwareSampleRate = recordingSession.sampleRate
            
            #elseif swift(>=4.0)
            try recordingSession.setCategory(AVAudioSessionCategoryPlayAndRecord, mode: AVAudioSessionModeDefault, options: AVAudioSessionCategoryOptions.defaultToSpeaker)
            #endif
            try recordingSession.setActive(true)
        } catch {
            print("Activating record session failed")
            return false
        }
        
        do {
            try recordingSession.setPreferredSampleRate(16000.0)
        } catch {
            print("Could not setup audio sample rate")
            return false
        }
        
        do {
            try recordingSession.setPreferredIOBufferDuration(0.005)
        } catch {
            print("Could not set buffer durations")
            return false
        }
        
        
        // Describe the audio unit
        var audioCompDesc: AudioComponentDescription = AudioComponentDescription()
        audioCompDesc.componentType = kAudioUnitType_Output
        audioCompDesc.componentSubType = kAudioUnitSubType_RemoteIO
        audioCompDesc.componentManufacturer = kAudioUnitManufacturer_Apple
        audioCompDesc.componentFlags = 0
        audioCompDesc.componentFlagsMask = 0
        
        let rioComponent = AudioComponentFindNext(nil, &audioCompDesc)
        error = AudioComponentInstanceNew(rioComponent!, &dataPtr.pointee.rioUnit)
        if (error != 0) {
            print(String(error) + ": Couldn't get RIO unit instance")
            return false
        }
        
        // Sets up RIO unit for playback
        var oneFlag: UInt32 = 1
        let bus0: AudioUnitElement = 0
        error = AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, bus0, &oneFlag, UInt32(MemoryLayout.size(ofValue: oneFlag)))
        
        // Enable RIO input
        let bus1: AudioUnitElement = 1
        error = error | AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, bus1, &oneFlag, UInt32(MemoryLayout.size(ofValue: oneFlag)))
        
        if (error != 0) {
            print(String(error) + ": Couldn't enable RIO input/output")
            return false
        }
        
        var myABSD = AudioStreamBasicDescription()

        myABSD.mSampleRate = 16000.0
        myABSD.mFormatID = kAudioFormatLinearPCM
        myABSD.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        myABSD.mBytesPerPacket = 2
        myABSD.mFramesPerPacket = 1
        myABSD.mBytesPerFrame = 2
        myABSD.mChannelsPerFrame = 1
        myABSD.mBitsPerChannel = 16
        
        // Setup stream format
        error = AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus0, &myABSD, UInt32(MemoryLayout.size(ofValue: myABSD)))
        error = error | AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus0, &myABSD, UInt32(MemoryLayout.size(ofValue: myABSD)))

        // Setup the maximum number of sample frames the render callback can expect in each call of the render function
        var maxFramesPerSlice: UInt32 = 4096
        error = error | AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, bus0, &maxFramesPerSlice, UInt32(MemoryLayout.size(ofValue: maxFramesPerSlice)))
        
        if (error != 0) {
            print(String(error) + ": Couldn't set ASBD for RIO input/output")
            return false
        }
        
        dataPtr.pointee.asbd = myABSD
        dataPtr.pointee.sineFrequency = 30
        dataPtr.pointee.sinePhase = 0
        
        var callbackStruct = AURenderCallbackStruct(inputProc: InputModulatingRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        error = AudioUnitSetProperty(dataPtr.pointee.rioUnit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, bus0, &callbackStruct, UInt32(MemoryLayout.size(ofValue: callbackStruct)))
        
        if (error != 0) {
            print(String(error) + ": Couldn't set RIO's input callback on bus 0")
            return false
        }
        
        error = AudioUnitInitialize(dataPtr.pointee.rioUnit!)
        
        if (error != 0) {
            print(String(error) + ": Couldn't initialize the RIO unit")
            return false
        }
        print("Setup successful")

        return true
    }
    
    func performRender(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ioPtr = UnsafeMutableAudioBufferListPointer(ioData)
        
        let bus1: UInt32 = 1
        var err = AudioUnitRender(dataPtr.pointee.rioUnit!, ioActionFlags, inTimeStamp, bus1, inNumberFrames, ioData)
        
        for i in 0..<ioPtr.count {
            memset(ioPtr[i].mData, 0, Int(ioPtr[i].mDataByteSize))
        }

        return err
    }
    /*
    private let InputModulatingRenderCallback: AURenderCallback? = {  inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        print("Finished")
        return(0)
    }
 */
    
    func setupNotifications() {
        // Handle interruptions
        let notificationCenter = NotificationCenter.default
    }
    
    func startRecording() {
        let status = AudioOutputUnitStart(dataPtr.pointee.rioUnit!)
        print(status)
    }
    
    func stopRecording() {
        let status = AudioOutputUnitStop(dataPtr.pointee.rioUnit!)
        print(status)
    }
    
    
    
    
    
    /*
    var audioStreamFormat: AudioStreamBasicDescription!
    var inQueue: AudioQueueRef? = nil
    var audioBuffer: AudioQueueBuffer!
    
    struct BufferRecordSettings {
        let format: AudioFormatID = kAudioFormatLinearPCM
        let formatFlags: UInt32 = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        let sampleRate: Double = 16000.0
        let numChannels: UInt32 = 1
    }
    
    struct AQRecorderState {
        let mDataFormat: AudioStreamBasicDescription?
        let mQueue: AudioQueueRef?
        let mBuffers: [AudioQueueBufferRef]?
        let bufferByteSize: UInt32?
        let mCurrentPacket: UInt32?
        let mIsRunning: Bool?
    }
    
    var recordSettings = BufferRecordSettings()
    var aqData = AQRecorderState(mDataFormat: nil, mQueue: nil, mBuffers: nil, bufferByteSize: nil, mCurrentPacket: nil, mIsRunning: false)
    
    var isReady = false
    var isRecording = false
    var recordingStarted = false
    var recordingTime = CACurrentMediaTime()
    var elapsed = 0.0
    //func audioQueueInputCallback(ptr: Optional<UnsafeMutableRawPointer>?, queueRef: AudioQueueBufferRef, bufferRef: AudioQueueBufferRef, timePtr: UnsafePointer<AudioTimeStamp>, n: UInt32, packetInfo: Optional<UnsafePointer<AudioStreamPacketDescription>>) -> Void {}
    
    private let audioQueueInputCallback: AudioQueueInputCallback = {
        userData, queue, bufferRef, startTimeRef, numPackets, packetDescriptions in
        // Process your audio once it has completed
        print("Finished")
    }
    
    override init() {
        super.init()
        setUpAudio()
    }
    
    func setUpAudio() {
        audioStreamFormat = AudioStreamBasicDescription(
            mSampleRate: self.recordSettings.sampleRate,
            mFormatID: self.recordSettings.format,
            mFormatFlags: self.recordSettings.formatFlags,
            mBytesPerPacket: 2 * self.recordSettings.numChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * self.recordSettings.numChannels,
            mChannelsPerFrame: self.recordSettings.numChannels,
            mBitsPerChannel: 16,
            mReserved: 0)
        
        print(audioStreamFormat!)
        let status = AudioQueueNewInput(&audioStreamFormat, audioQueueInputCallback, nil, nil, nil, 0, &inQueue)
        
        if (status == 0) {
            print("Setup successful")
            self.aqData = AQRecorderState(
                mDataFormat: audioStreamFormat,
                mQueue: inQueue!,
                mBuffers: [AudioQueueBufferRef](),
                bufferByteSize: 32,
                mCurrentPacket: 0,
                mIsRunning: false
            )
            isReady = true
        }
    }
    
    // Starts an indefinite audio recording
    public func startRecording() {
        if (!isReady) {
            print("Audio must be successfully initialized first")
        } else if (isRecording) {
            print("Audio already recording")
        } else {
            let status = AudioQueueStart(inQueue!, nil)
            if (status == 0) {
                recordingTime = CACurrentMediaTime()
                isRecording = true
                
                if (!recordingStarted) {
                    elapsed = 0
                    recordingStarted = true
                }
                print("Recording started...")
            } else {
                print("Failed to start recording")
            }
        }
    }
    
    // Starts an audio recording of fixed length; this cannot be paused or stopped; terminates automatically
    public func startRecording(milliseconds: Int, completionHandler: @escaping (Bool) -> Void) {
        if (!isReady) {
            print("Audio must be successfully initialized first")
        } else if (isRecording) {
            print("Audio already recording")
        } else {
            let status = AudioQueueStart(inQueue!, nil)
            if (status == 0) {
                recordingTime = CACurrentMediaTime()
                isRecording = true
                
                if (!recordingStarted) {
                    elapsed = 0
                    recordingStarted = true
                }
                print("Timed recording started...")
                
                DispatchQueue.global().async {
                    sleep(2)
                    let status = AudioQueueStop(self.inQueue!, true)
                    if (status == 0) {
                        self.isRecording = false
                        self.recordingStarted = false
                        print("Stopped timed recording.")
                        completionHandler(true)
                    } else {
                        print("Failed to stop timed recording.")
                        completionHandler(false)
                    }
                }
            } else {
                print("Failed to start timed recording.")
            }
        }
    }
    
    // Pauses currently playing audio recording
    public func pauseRecording() {
        if (!isReady) {
            print("Audio must be successfully initialized first")
        } else if (!isRecording) {
            print("Audio already paused/stopped")
        } else {
            let status = AudioQueuePause(inQueue!)
            if (status == 0) {
                isRecording = false
                elapsed += (CACurrentMediaTime() - recordingTime)
                recordingTime = 0
                print("Recording paused...")
            } else {
                print("Failed to start recording")
            }
        }
    }
    
    // Terminates currently playing audio recording
    public func stopRecording() {
        if (!isReady) {
            print("Audio must be successfully initialized first")
        } else {
            let status = AudioQueueStop(inQueue!, true)
            if (status == 0) {
                isRecording = false
                recordingStarted = false
                print("Stopped.")
            } else {
                print("Failed to stop.")
            }
        }
    }
 */
}
