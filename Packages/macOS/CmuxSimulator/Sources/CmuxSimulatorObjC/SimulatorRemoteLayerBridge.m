#import "CmuxSimulatorObjC.h"

BOOL CmuxSimulatorSetRemoteLayerContext(CALayer *layer, uint32_t contextID) {
    @try {
        [layer setValue:@(contextID) forKey:@"contextId"];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
