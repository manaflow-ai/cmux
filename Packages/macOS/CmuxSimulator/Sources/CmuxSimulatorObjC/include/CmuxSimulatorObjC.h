#import <QuartzCore/QuartzCore.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Assigns a remote Core Animation context while containing Objective-C exceptions.
FOUNDATION_EXPORT BOOL CmuxSimulatorSetRemoteLayerContext(
    CALayer *layer,
    uint32_t contextID
);

NS_ASSUME_NONNULL_END
