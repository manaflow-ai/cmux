// QuartzCore's remote layer class, declared the way Chromium declares it
// (ui/base/cocoa/remote_layer_api.h): a CALayer that shows the root layer of
// a Core Animation context named by its WindowServer id, from this process or
// another. A Chromium page's pixels reach the cmux window's layer tree through
// one (plans/cmux-next/cef-layer-hosting-DESIGN.md). QuartzCore exports the
// class, so a missing class fails at link time, not through a selector lookup.
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

NS_ASSUME_NONNULL_END
