#import "RNAudioRecord.h"

@interface RNAudioRecord ()
@property (nonatomic, nullable, copy) AVAudioSessionCategory previousCategory;
@end


@implementation RNAudioRecord

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(init:(NSDictionary *) options) {
    RCTLogInfo(@"init");
    _recordState.mDataFormat.mSampleRate        = options[@"sampleRate"] == nil ? 44100 : [options[@"sampleRate"] doubleValue];
    _recordState.mDataFormat.mBitsPerChannel    = options[@"bitsPerSample"] == nil ? 16 : [options[@"bitsPerSample"] unsignedIntValue];
    _recordState.mDataFormat.mChannelsPerFrame  = options[@"channels"] == nil ? 1 : [options[@"channels"] unsignedIntValue];
    _recordState.mDataFormat.mBytesPerPacket    = (_recordState.mDataFormat.mBitsPerChannel / 8) * _recordState.mDataFormat.mChannelsPerFrame;
    _recordState.mDataFormat.mBytesPerFrame     = _recordState.mDataFormat.mBytesPerPacket;
    _recordState.mDataFormat.mFramesPerPacket   = 1;
    _recordState.mDataFormat.mReserved          = 0;
    _recordState.mDataFormat.mFormatID          = kAudioFormatLinearPCM;
    _recordState.mDataFormat.mFormatFlags       = _recordState.mDataFormat.mBitsPerChannel == 8 ? kLinearPCMFormatFlagIsPacked : (kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked);


    _recordState.bufferByteSize = 2048;
    _recordState.mSelf = self;

    NSString *fileName = options[@"wavFile"] == nil ? @"audio.wav" : options[@"wavFile"];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    _filePath = [NSString stringWithFormat:@"%@/%@", docDir, fileName];
    [RNAudioRecord createDir:_filePath];
}

RCT_EXPORT_METHOD(start) {
    RCTLogInfo(@"start");

    [self savePreviousCategory];

    // most audio players set session category to "Playback", record won't work in this mode
    // therefore set session category to "Record" before recording
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];

    _recordState.mIsRunning = true;
    _recordState.mCurrentPacket = 0;

    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
    AudioFileCreateWithURL(url, kAudioFileWAVEType, &_recordState.mDataFormat, kAudioFileFlags_EraseFile, &_recordState.mAudioFile);
    CFRelease(url);

    AudioQueueNewInput(&_recordState.mDataFormat, HandleAudioInputBuffer, &_recordState, NULL, NULL, 0, &_recordState.mQueue);
    for (int i = 0; i < kNumberBuffers; i++) {
        AudioQueueAllocateBuffer(_recordState.mQueue, _recordState.bufferByteSize, &_recordState.mBuffers[i]);
        AudioQueueEnqueueBuffer(_recordState.mQueue, _recordState.mBuffers[i], 0, NULL);
    }
    AudioQueueStart(_recordState.mQueue, NULL);
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject) {
    RCTLogInfo(@"stop");
    if (_recordState.mIsRunning) {
        _recordState.mIsRunning = false;
        AudioQueueStop(_recordState.mQueue, true);
        AudioQueueDispose(_recordState.mQueue, true);
        AudioFileClose(_recordState.mAudioFile);
    }
    [self restorePreviousCategory];
    resolve(_filePath);
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
    RCTLogInfo(@"file path %@", _filePath);
    RCTLogInfo(@"file size %llu", fileSize);
}

-(float)getCurrentPower {

  UInt32 dataSize = sizeof(AudioQueueLevelMeterState) * _recordState.mDataFormat.mChannelsPerFrame;
  AudioQueueLevelMeterState *levels = (AudioQueueLevelMeterState*)malloc(dataSize);

  OSStatus rc = AudioQueueGetProperty(_recordState.mQueue, kAudioQueueProperty_CurrentLevelMeter, levels, &dataSize);
  if (rc) {
//    NSLog(@"NoiseLeveMeter>>takeSample - AudioQueueGetProperty(CurrentLevelMeter) returned %@", rc);
  }

  float channelAvg = 0;
  for (int i = 0; i < _recordState.mDataFormat.mChannelsPerFrame; i++) {
    channelAvg += levels[i].mPeakPower;
  }
  free(levels);

  // This works because in this particular case one channel always has an mAveragePower of 0.
  return channelAvg;
}

void HandleAudioInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc) {
    AQRecordState* pRecordState = (AQRecordState *)inUserData;

    if (!pRecordState->mIsRunning) {
        return;
    }

    if (AudioFileWritePackets(pRecordState->mAudioFile,
                              false,
                              inBuffer->mAudioDataByteSize,
                              inPacketDesc,
                              pRecordState->mCurrentPacket,
                              &inNumPackets,
                              inBuffer->mAudioData
                              ) == noErr) {
        pRecordState->mCurrentPacket += inNumPackets;
    }

    float volume = [pRecordState->mSelf getCurrentPower];
    [pRecordState->mSelf sendEventWithName:@"data" body:[NSNumber numberWithFloat:volume]];

    AudioQueueEnqueueBuffer(pRecordState->mQueue, inBuffer, 0, NULL);
    [self enableUpdateLevelMetering];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"data"];
}

- (void)dealloc {
    RCTLogInfo(@"dealloc");
    AudioQueueDispose(_recordState.mQueue, true);
}

// 创建录音文件目录
+ (void)createDir: (NSString *) filePath {
    NSString *audioFileDirPath = [filePath stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDir = NO;

    BOOL existed = [fileManager fileExistsAtPath:audioFileDirPath isDirectory:&isDir];

    if (!(isDir && existed)) {
        [fileManager createDirectoryAtPath:audioFileDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (void)savePreviousCategory {
    self.previousCategory = [AVAudioSession sharedInstance].category;
}

- (void)restorePreviousCategory {
    if (self.previousCategory) {
        [[AVAudioSession sharedInstance] setCategory:self.previousCategory error:nil];
        self.previousCategory = nil;
    }
}

- (BOOL)enableUpdateLevelMetering
{
    UInt32 val = 1;
    OSStatus status = AudioQueueSetProperty(_recordState.mQueue, kAudioQueueProperty_EnableLevelMetering, &val, sizeof(UInt32));
    if( status == kAudioSessionNoError )
    {
        return YES;
    }

    return NO;
}

@end
