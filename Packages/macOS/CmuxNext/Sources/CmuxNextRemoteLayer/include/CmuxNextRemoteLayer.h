// QuartzCore's remote layer class, declared the way Chromium declares it
// (ui/base/cocoa/remote_layer_api.h): a CALayer that shows the root layer of
// a Core Animation context named by its WindowServer id, from this process or
// another. A Chromium page's pixels reach the cmux window's layer tree through
// one (plans/cmux-next/cef-layer-hosting-DESIGN.md). QuartzCore exports the
// class, so a missing class fails at link time, not through a selector lookup.
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_types.h>

#import "CmuxNextRemoteAccessibility.h"

NS_ASSUME_NONNULL_BEGIN

@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

// The Core Animation context a window's layer tree commits through, with its
// fence ports (WebKit's Source/WebCore/PAL/pal/spi/cocoa/QuartzCoreSPI.h): a
// commit of a context that has a fence port set is applied by the render
// server only when every send right to that port is gone, so two contexts that
// share a fence (cmux's window and a Chromium page's GPU context) show their
// frames together. The render server waits; the committing thread never does.
@interface CAContext : NSObject
@property(readonly) uint32_t contextId;
// A new fence port; the caller owns one send right.
- (mach_port_t)createFencePort;
// This context's next commit waits for `port` (every send right released).
- (void)setFencePort:(mach_port_t)port;
@end

@interface CALayer (CmuxNextRemoteLayer)
// The context the layer's tree commits through; nil outside a window.
- (nullable CAContext*)context;
@end

// Commit phases of the current transaction, as Chromium
// (ui/accelerated_widget_mac/ca_transaction_observer.mm) and WebKit
// (QuartzCoreSPI.h) declare them: PostCommit is 2.
typedef enum {
  kCATransactionPhasePreLayout,
  kCATransactionPhasePreCommit,
  kCATransactionPhasePostCommit,
  kCATransactionPhaseNull = ~0u
} CATransactionPhase;

@interface CATransaction (CmuxNextRemoteLayer)
// Runs `block` once when the current transaction reaches `phase`. NO when the
// handler was not added (the phase has passed): `block` never runs.
+ (BOOL)addCommitHandler:(void (^)(void))block forPhase:(CATransactionPhase)phase;
@end

NS_ASSUME_NONNULL_END
