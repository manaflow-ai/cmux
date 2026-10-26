// AppKit's remote accessibility element, declared the way Chromium declares
// it (ui/base/cocoa/remote_accessibility_api.h): an element of this process's
// accessibility tree that stands for an element of another process, named by
// the token that process made for it. A Chromium page whose browser runs in
// the Chromium Host reaches the cmux window's accessibility tree through one
// (plans/cmux-next/chrome-parity/p01-process.md, task 049), as a Chrome app
// shim's window reaches the browser process's views (remote_cocoa) and a
// WKWebView reaches its web process. AppKit exports the class, so a missing
// class fails at link time, not through a selector lookup.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSAccessibilityRemoteUIElement : NSObject
// Lets this process present the elements of process `pid`.
+ (void)registerRemoteUIProcessIdentifier:(int)pid NS_SWIFT_NAME(registerRemoteUIProcess(_:));
// The token another process makes a remote element for `element` from.
+ (nullable NSData*)remoteTokenForLocalUIElement:(id)element NS_SWIFT_NAME(remoteToken(forLocalElement:));
- (nullable instancetype)initWithRemoteToken:(NSData*)token NS_SWIFT_NAME(init(remoteToken:));
// The process whose element this stands for.
- (pid_t)processIdentifier NS_SWIFT_NAME(remoteProcessIdentifier());
// The element under `point` (screen coordinates) in the remote tree.
- (nullable id)accessibilityHitTest:(NSPoint)point;
@property(retain, nullable) id windowUIElement;
@property(retain, nullable) id topLevelUIElement;
@end

NS_ASSUME_NONNULL_END
