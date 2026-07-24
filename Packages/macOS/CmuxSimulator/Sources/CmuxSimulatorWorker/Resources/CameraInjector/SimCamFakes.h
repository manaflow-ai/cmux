// Adapted from serve-sim commit af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 (Apache-2.0).
// Modified by cmux for native worker integration.

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>

#pragma mark - Mirror mode

typedef NS_ENUM(NSInteger, SimCamMirrorMode) {
    SimCamMirrorAuto = 0,
    SimCamMirrorForceOn,
    SimCamMirrorForceOff,
};

SimCamMirrorMode SimCamGetMirrorMode(void);
void SimCamSetMirrorMode(SimCamMirrorMode m);
BOOL SimCamShouldMirror(AVCaptureDevicePosition p);

void SimCamReadMirrorModeFromEnv(void);

#pragma mark - Position tag

AVCaptureDevicePosition SimCamPositionOf(id obj);
void SimCamSetPosition(id obj, AVCaptureDevicePosition p);

#pragma mark - Camera-in-use sticky flag

BOOL SimCamCameraIsInUse(void);
void SimCamMarkCameraInUse(void);
void SimCamMarkSessionUsingFakeCamera(id session, BOOL usingFakeCamera);

#pragma mark - AVF runtime-error notification suppression

BOOL SimCamShouldSwallowAVFRuntimeError(NSNotificationName name, id object);
void SimCamLogSwallowedRuntimeError(NSString *via, id object, NSDictionary *userInfo);

#pragma mark - Fake objects

@interface SimCamWeakRef : NSObject
@property (nonatomic, weak) id target;
@end

@interface SimCamFakeFormat : AVCaptureDeviceFormat
@end
@interface SimCamFakeDevice : AVCaptureDevice
@end
@interface SimCamFakeConnection : AVCaptureConnection
@end
@interface SimCamFakeResolvedPhotoSettings : AVCaptureResolvedPhotoSettings
@end

@interface SimCamFakePhoto : AVCapturePhoto
+ (instancetype)photoFromImage:(CGImageRef)cgImage
                   jpegQuality:(CGFloat)q
                      mirrored:(BOOL)mirrored;
@end

@interface SimCamAttitude : CMAttitude
@end
@interface SimCamAccelerometerData : CMAccelerometerData
@end
@interface SimCamGyroData : CMGyroData
@end
@interface SimCamMagnetometerData : CMMagnetometerData
@end
@interface SimCamDeviceMotion : CMDeviceMotion
@end

#pragma mark - Fake-object factories / caches

AVCaptureDeviceFormat *SimCamSharedFakeFormat(void);
AVCaptureDevice *SimCamFakeDeviceForPosition(AVCaptureDevicePosition p);
AVCaptureDeviceInput *SimCamFakeInputForPosition(AVCaptureDevicePosition p);

AVCaptureConnection *SimCamFakeConnectionForOutput(AVCaptureOutput *out);
void SimCamSetOutputInput(AVCaptureOutput *out, AVCaptureInput *input);
AVCaptureInput *SimCamOutputInput(AVCaptureOutput *out);

CMAttitude *SimCamSharedAttitude(void);
CMAccelerometerData *SimCamSharedAccelerometerData(void);
CMGyroData *SimCamSharedGyroData(void);
CMMagnetometerData *SimCamSharedMagnetometerData(void);
CMDeviceMotion *SimCamSharedDeviceMotion(void);

#pragma mark - Fake-input marking (used by AVCaptureDeviceInput swizzle)

void SimCamMarkFakeInput(id input, AVCaptureDevice *fakeDevice);
BOOL SimCamIsFakeInput(id input);
AVCaptureDevice *SimCamFakeInputDevice(id input);
