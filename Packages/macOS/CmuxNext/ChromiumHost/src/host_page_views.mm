// The host's views behind cmux's page view tokens (host_dispatch.h, PageViews).

#import <AppKit/AppKit.h>

#include "host_dispatch.h"

// A page view's window: never key or main, so a click or an accessibility
// focus on it cannot activate the host. Input comes from cmux over the wire.
@interface ChromiumHostPageWindow : NSWindow
@end

@implementation ChromiumHostPageWindow
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

// The parent view of a page window. Its occlusion rect (the fork's
// -cmuxOcclusionRects) covers it, so the fork's tracker keeps the page
// window from taking the mouse; on each tracker read Chromium's page window
// (a child of this view's window until it is detached) is made to ignore the
// mouse too.
@interface ChromiumHostParentView : NSView
@end

@implementation ChromiumHostParentView
- (BOOL)isFlipped {
  return NO;
}
- (NSArray<NSValue*>*)cmuxOcclusionRects {
  return @[ [NSValue valueWithRect:self.bounds] ];
}
- (NSBezierPath*)cmuxClipPath {
  for (NSWindow* child in self.window.childWindows) child.ignoresMouseEvents = YES;
  return nil;
}
@end

namespace cmux_host {
namespace {

// A page window's size until cmux sends the page view's geometry (Place).
constexpr CGFloat kDefaultPageWidth = 800;
constexpr CGFloat kDefaultPageHeight = 600;

}  // namespace

HostPageViews::~HostPageViews() {
  for (auto& [token, window] : windows_) {
    NSWindow* page_window = (__bridge NSWindow*)window;
    [page_window close];
    [page_window release];
  }
}

void* HostPageViews::Open(uint64_t token) {
  auto found = windows_.find(token);
  if (found != windows_.end()) return (__bridge void*)((__bridge NSWindow*)found->second).contentView;
  const NSRect frame = NSMakeRect(0, 0, kDefaultPageWidth, kDefaultPageHeight);
  ChromiumHostPageWindow* window = [[ChromiumHostPageWindow alloc] initWithContentRect:frame
                                                                             styleMask:NSWindowStyleMaskBorderless
                                                                               backing:NSBackingStoreBuffered
                                                                                 defer:NO];
  window.releasedWhenClosed = NO;
  window.opaque = NO;
  window.backgroundColor = NSColor.clearColor;
  window.hasShadow = NO;
  window.ignoresMouseEvents = YES;
  window.collectionBehavior = NSWindowCollectionBehaviorIgnoresCycle;
  ChromiumHostParentView* view = [[ChromiumHostParentView alloc] initWithFrame:frame];
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.alphaValue = 0;
  window.contentView = view;
  [view release];
  // Never ordered in: the page window under the view is detached once its
  // layers are hosted (HostContext::HandleLayerHosting), and cmux gives the
  // page its visibility (set_page_visibility), so no window of the host
  // is ever on screen. The window only carries the page's place and screen
  // (Place), as Chrome's browser process keeps a window's bounds in
  // NativeWidgetMacNSWindowHost while the app shim shows the window
  // (ui/views/cocoa/native_widget_mac_ns_window_host.mm).
  windows_[token] = (__bridge void*)window;
  return (__bridge void*)window.contentView;
}

void HostPageViews::Place(uint64_t token, const PageGeometry& geometry) {
  auto found = windows_.find(token);
  if (found == windows_.end()) return;
  NSWindow* page_window = (__bridge NSWindow*)found->second;
  [page_window setFrame:NSMakeRect(geometry.screen_x, geometry.screen_y, geometry.width, geometry.height) display:NO];
}

// The page window follows its parent view, as in cmux the fork's page window
// follows CEFHostView: its tracker re-reads the view on the parent view
// geometry post (CEFHostView.postGeometryChange). Only on change (task 053).
void HostPageViews::Resize(uint64_t token, int32_t width, int32_t height) {
  auto found = windows_.find(token);
  if (found == windows_.end()) return;
  NSWindow* page_window = (__bridge NSWindow*)found->second;
  const NSSize size = NSMakeSize(width, height);
  if (NSEqualSizes(page_window.contentView.frame.size, size)) return;
  [page_window setContentSize:size];
  [NSNotificationCenter.defaultCenter postNotificationName:@"CmuxParentViewGeometryDidChange"
                                                    object:page_window.contentView];
}

void HostPageViews::Close(uint64_t token) {
  auto found = windows_.find(token);
  if (found == windows_.end()) return;
  NSWindow* page_window = (__bridge NSWindow*)found->second;
  [page_window close];
  [page_window release];
  windows_.erase(found);
}

}  // namespace cmux_host
