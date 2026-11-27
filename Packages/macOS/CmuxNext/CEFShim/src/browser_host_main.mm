// cmux Chromium host (prototype; plans/cmux-next/cef-helper-app-DESIGN.md).
//
// Chromium's browser process in its own app, so a CHECK or crash in it ends
// only this process, and its message pump runs on this process's main thread,
// never on cmux's. One Chrome-style page per host. The page draws into a Core
// Animation context (fork API 26, cmux_browser_set_layer_hosting) whose id
// goes to cmux, which shows it in a pane with a CALayerHost. cmux forwards
// mouse and key events over the wire (chromium_host_wire.h); they reach
// Chromium through CefBrowserHost::Send*Event.
//
// The page window sits in a transparent, click-through window of this
// process at the pane's screen rect: it has no pixels while hosted, and the
// parent view's occlusion rect (the fork's -cmuxOcclusionRects) covers it, so
// the fork's tracker never lets it take the mouse.
//
// Launched by cmux (ChromiumHostLauncher) with the wire on fd 3 (frames from cmux) and fd 4 (frames to cmux):
//   <host> --framework=<CEF framework dir> --subprocess=<base helper exe>
//          --root-cache=<dir> [--log-file=<path>] [--cef-switch=<name[=value]>]...
// EOF on fd 3 (cmux quit or crashed) closes the page and ends the host.
//
// --remote-cocoa (fork API 37, in-tree pages approach 4): no layer hosting
// and no forwarded input. The host listens for cmux's remote_cocoa connection
// (cmux_rc_host_listen; only its parent, cmux, may connect) and sends cmux the
// bootstrap name; once cmux connected and named its view (kAttach), the
// page's own WebContentsViewCocoa and RenderWidgetHostViewCocoa are made in
// cmux's process inside that view (cmux_browser_set_remote_cocoa_hosting),
// as Chrome's PWA app shims get theirs. Input, IME, cursor, drag and the
// page's pixels (its compositor's CALayerHost) are then Chromium's own Cocoa
// code in cmux; this process sees them over mojo.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <thread>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_keyboard_handler.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#include "chromium_host_wire.h"
#include "command_line_apply.h"
#include "page_scheme_registration.h"

@interface ChromiumHostApplication : NSApplication <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation ChromiumHostApplication
- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

// The activation probe (MEASUREMENT BRANCH ONLY; in-tree pages approach 4, rc-diag-1). On the other Mac each remote
// page's host became the front app as its page opened (lsappinfo front: the host's pid, cmux's bundle id; cmux itself
// never active), though this process is Accessory, orders its window with orderFrontRegardless and never calls
// SetFocus in remote mode. This writes one line per call to every activation entry this process can reach, with the
// stack (image + offset per frame, for atos against the framework's dSYM) for the first 4 calls of each, and the
// activation policy at each step of a page's life, to /tmp/cmux-host-activation/host-<pid>.log (and NSLog):
// -[NSApplication activateIgnoringOtherApps:], -activate, -setActivationPolicy:, -[NSRunningApplication
// activateWithOptions:] and -activateFromApplication:options:, -[NSWindow makeKeyAndOrderFront:], the app's own
// will/did become active and did resign active notifications, and the workspace's did-activate notification (which
// pid became active). TransformProcessType and SetFrontProcess need no hook: the framework imports neither
// (dyld_info -imports, cef-157-remote-cocoa-4) and this file calls neither.
namespace actprobe {

FILE* g_file = nullptr;
NSMutableDictionary<NSString*, NSNumber*>* g_counts = nil;

uint64_t UptimeNs() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

FILE* File() {
  if (g_file) return g_file;
  mkdir("/tmp/cmux-host-activation", 0755);
  char path[256];
  snprintf(path, sizeof path, "/tmp/cmux-host-activation/host-%d.log", getpid());
  g_file = fopen(path, "a");
  return g_file;
}

NSString* Stack() {
  NSMutableArray<NSString*>* frames = [NSMutableArray array];
  NSArray<NSNumber*>* addresses = [NSThread callStackReturnAddresses];
  for (NSUInteger i = 2; i < addresses.count && i < 40; i++) {  // skip this function and the hook
    void* pc = reinterpret_cast<void*>(addresses[i].unsignedLongLongValue);
    Dl_info info = {};
    if (dladdr(pc, &info) && info.dli_fbase) {
      const char* slash = info.dli_fname ? strrchr(info.dli_fname, '/') : nullptr;
      [frames addObject:[NSString stringWithFormat:@"%s+0x%llx%s%s", slash ? slash + 1 : "?",
                                                   (unsigned long long)((uintptr_t)pc - (uintptr_t)info.dli_fbase),
                                                   info.dli_sname ? ":" : "", info.dli_sname ? info.dli_sname : ""]];
    } else {
      [frames addObject:[NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)pc]];
    }
  }
  return [frames componentsJoinedByString:@" | "];
}

void Line(NSString* event, NSString* detail, bool withStack) {
  @autoreleasepool {
  NSRunningApplication* front = NSWorkspace.sharedWorkspace.frontmostApplication;
  NSString* line = [NSString stringWithFormat:@"actprobe t=%.6f pid=%d event=%@ policy=%ld active=%d front_pid=%d%@%@%@",
                    UptimeNs() / 1e9, getpid(), event, (long)NSApp.activationPolicy, NSApp.isActive ? 1 : 0,
                    front ? front.processIdentifier : -1, detail.length ? @" " : @"", detail ?: @"",
                    withStack ? [@" stack=" stringByAppendingString:Stack()] : @""];
  if (FILE* f = File()) {
    fprintf(f, "%s\n", line.UTF8String);
    fflush(f);
  }
  NSLog(@"%@", line);
  }
}

// One call: its line, with the stack for the first 4 of this kind.
void Call(NSString* kind, NSString* detail) {
  if (!g_counts) g_counts = [NSMutableDictionary dictionary];
  const long n = g_counts[kind].longValue + 1;
  g_counts[kind] = @(n);
  Line(kind, [NSString stringWithFormat:@"n=%ld%@%@", n, detail.length ? @" " : @"", detail ?: @""], n <= 4);
}

// The originals the hooks call (this file is built without ARC: imp_implementationWithBlock copies each block).
IMP g_activate_ignoring = nullptr, g_activate = nullptr, g_set_policy = nullptr, g_running_activate = nullptr,
    g_running_from = nullptr, g_make_key = nullptr;

IMP Wrap(Class cls, SEL selector, id block) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) {
    Line(@"no_method", [NSString stringWithFormat:@"class=%@ sel=%@", NSStringFromClass(cls),
                                                  NSStringFromSelector(selector)], false);
    return nullptr;
  }
  IMP original = method_getImplementation(method);
  IMP replacement = imp_implementationWithBlock(block);
  if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
    method_setImplementation(method, replacement);
  }
  return original;
}

void Install() {
  if (!g_counts) g_counts = [[NSMutableDictionary alloc] init];
  Class app = [NSApplication class];
  g_activate_ignoring = Wrap(app, @selector(activateIgnoringOtherApps:), ^(id _self, BOOL flag) {
    Call(@"activateIgnoringOtherApps", [NSString stringWithFormat:@"flag=%d", flag ? 1 : 0]);
    reinterpret_cast<void (*)(id, SEL, BOOL)>(g_activate_ignoring)(_self, @selector(activateIgnoringOtherApps:), flag);
  });
  if ([NSApplication instancesRespondToSelector:@selector(activate)]) {
    g_activate = Wrap(app, @selector(activate), ^(id _self) {
      Call(@"activate", nil);
      reinterpret_cast<void (*)(id, SEL)>(g_activate)(_self, @selector(activate));
    });
  }
  g_set_policy = Wrap(app, @selector(setActivationPolicy:), ^BOOL(id _self, NSApplicationActivationPolicy policy) {
    Call(@"setActivationPolicy", [NSString stringWithFormat:@"to=%ld", (long)policy]);
    return reinterpret_cast<BOOL (*)(id, SEL, NSApplicationActivationPolicy)>(g_set_policy)(
        _self, @selector(setActivationPolicy:), policy);
  });
  Class running = [NSRunningApplication class];
  g_running_activate = Wrap(running, @selector(activateWithOptions:),
                            ^BOOL(NSRunningApplication* _self, NSApplicationActivationOptions options) {
    Call(@"runningActivateWithOptions", [NSString stringWithFormat:@"target_pid=%d options=%lu",
                                         _self.processIdentifier, (unsigned long)options]);
    return reinterpret_cast<BOOL (*)(id, SEL, NSApplicationActivationOptions)>(g_running_activate)(
        _self, @selector(activateWithOptions:), options);
  });
  static SEL from = NSSelectorFromString(@"activateFromApplication:options:");
  if ([NSRunningApplication instancesRespondToSelector:from]) {
    g_running_from = Wrap(running, from, ^BOOL(NSRunningApplication* _self, NSRunningApplication* source,
                                               NSApplicationActivationOptions options) {
      Call(@"runningActivateFromApplication", [NSString stringWithFormat:@"target_pid=%d source_pid=%d options=%lu",
                                               _self.processIdentifier, source.processIdentifier,
                                               (unsigned long)options]);
      return reinterpret_cast<BOOL (*)(id, SEL, id, NSApplicationActivationOptions)>(g_running_from)(_self, from, source,
                                                                                                    options);
    });
  }
  g_make_key = Wrap([NSWindow class], @selector(makeKeyAndOrderFront:), ^(NSWindow* _self, id sender) {
    Call(@"makeKeyAndOrderFront", [NSString stringWithFormat:@"window=%@#%ld level=%ld",
                                   NSStringFromClass([_self class]), (long)_self.windowNumber, (long)_self.level]);
    reinterpret_cast<void (*)(id, SEL, id)>(g_make_key)(_self, @selector(makeKeyAndOrderFront:), sender);
  });
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSApplicationWillBecomeActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification*) { Call(@"will_become_active", nil); }];
  [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification*) { Call(@"did_become_active", nil); }];
  [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification*) { Call(@"did_resign_active", nil); }];
  [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                  usingBlock:^(NSNotification*) { Call(@"did_finish_launching", nil); }];
  [NSWorkspace.sharedWorkspace.notificationCenter
      addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
              usingBlock:^(NSNotification* note) {
                NSRunningApplication* a = note.userInfo[NSWorkspaceApplicationKey];
                Line(@"workspace_did_activate", [NSString stringWithFormat:@"app_pid=%d app=%@ is_self=%d",
                                                 a.processIdentifier, a.bundleIdentifier,
                                                 a.processIdentifier == getpid() ? 1 : 0], false);
              }];
  Line(@"installed", nil, false);
}

// The policy and activity at a step of the page's life (no stack).
void Step(const char* where) {
  Line([NSString stringWithFormat:@"step:%s", where], nil, false);
}

}  // namespace actprobe

namespace {

uint64_t Now() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// Everything below is touched on the UI thread (this process's main thread)
// only. The reader thread owns fd 3; the UI thread writes fd 4.
constexpr int kFromCmux = 3;
int g_to_cmux = -1;
int g_fork_api = 0;
uint32_t (*g_set_layer_hosting)(int, int) = nullptr;
CefRefPtr<CefBrowser> g_browser;
bool g_creating = false;
bool g_closing = false;
NSWindow* g_window = nil;
NSView* g_parent = nil;
NSRect g_screen_rect = NSZeroRect;
std::string g_pending_url;
uint32_t g_context = 0;
bool g_hosting_scheduled = false;
std::vector<uint32_t> g_hop_us;
int g_refused_frames = 0;

// Remote Cocoa (--remote-cocoa, fork API 37).
bool g_remote = false;
uint64_t g_remote_view = 0;
bool g_remote_attached = false;
int (*g_rc_listen)(int, void (*)(int, void*), void*, char*, int) = nullptr;
int (*g_rc_connected)() = nullptr;
int (*g_set_remote_hosting)(int, uint64_t) = nullptr;

void Send(cmux_host::Header h, const std::string& payload = std::string()) {
  if (g_to_cmux < 0) return;
  h.payload = static_cast<uint32_t>(std::min<size_t>(payload.size(), cmux_host::kMaxPayload));
  std::vector<uint8_t> bytes(cmux_host::kHeaderSize + h.payload);
  cmux_host::Encode(h, bytes.data());
  std::memcpy(bytes.data() + cmux_host::kHeaderSize, payload.data(), h.payload);
  size_t sent = 0;
  while (sent < bytes.size()) {
    ssize_t n = write(g_to_cmux, bytes.data() + sent, bytes.size() - sent);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return;  // cmux is gone; the reader sees EOF and ends the host
    sent += static_cast<size_t>(n);
  }
}

void SendText(uint32_t kind, const std::string& text) {
  cmux_host::Header h;
  h.kind = kind;
  Send(h, text);
}

// The remote Cocoa resize probe (measurement builds, approaches/remote-cocoa): during a window drag the remote pages
// sat off their panes by the panes' height change (slope 0.50 of the window's, r 1.00), and flipping cmux's container
// changed nothing (rc-win-2-fix). Each line names this process's own view of the page at the moment it changes: the
// geometry cmux sent (g_screen_rect, bottom-left screen points), the page window (g_window) and its content view, and
// every WebContentsViewCocoa and RenderWidgetHostViewCocoa this process keeps (the in-process NSViews a remote page
// keeps beside the ones in cmux), each as its frame in its window, its window's frame, and whether it and its
// superview are flipped. cmux writes each line into its live-resize log beside the step it arrived in (kDiag).
NSString* DiagRect(NSRect r) {
  return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

void DiagViews(const char* why);

NSMutableSet<NSValue*>* g_diag_watched = nil;

void DiagWatch(NSView* view) {
  if (!g_diag_watched) g_diag_watched = [NSMutableSet set];
  NSValue* key = [NSValue valueWithNonretainedObject:view];
  if ([g_diag_watched containsObject:key]) return;
  [g_diag_watched addObject:key];
  view.postsFrameChangedNotifications = YES;
  [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification
                                                  object:view
                                                   queue:nil
                                              usingBlock:^(NSNotification*) { DiagViews("view_frame"); }];
}

void DiagViews(const char* why) {
  if (!g_remote) return;
  NSMutableString* line = [NSMutableString stringWithFormat:@"why=%s geo=%@", why, DiagRect(g_screen_rect)];
  if (g_window) {
    [line appendFormat:@" win=%@ content=%@ content_flipped=%d", DiagRect(g_window.frame),
                       DiagRect(g_window.contentView.frame), g_window.contentView.isFlipped ? 1 : 0];
  }
  for (NSWindow* window in NSApp.windows) {
    NSMutableArray<NSView*>* stack = [NSMutableArray array];
    if (window.contentView) [stack addObject:window.contentView];
    while (stack.count) {
      NSView* view = stack.lastObject;
      [stack removeLastObject];
      NSString* name = NSStringFromClass([view class]);
      const bool rwhv = [name hasSuffix:@"RenderWidgetHostViewCocoa"];
      const bool wcvc = [name hasSuffix:@"WebContentsViewCocoa"];
      if (rwhv || wcvc) {
        DiagWatch(view);
        [line appendFormat:@" %s=%@ in_win=%ld win_frame=%@ flipped=%d super_flipped=%d hidden=%d",
                           rwhv ? "rwhv" : "wcvc", DiagRect([view convertRect:view.bounds toView:nil]),
                           (long)window.windowNumber, DiagRect(window.frame), view.isFlipped ? 1 : 0,
                           view.superview.isFlipped ? 1 : 0, view.isHiddenOrHasHiddenAncestor ? 1 : 0];
      }
      for (NSView* sub in view.subviews) [stack addObject:sub];
    }
  }
  cmux_host::Header h;
  h.kind = cmux_host::kDiag;
  h.t0 = Now();
  Send(h, std::string(line.UTF8String));
}

void CloseHost() {
  if (g_closing) return;
  g_closing = true;
  if (g_browser) {
    g_browser->GetHost()->CloseBrowser(true);  // OnBeforeClose quits the loop
  } else {
    CefQuitMessageLoop();
  }
}

void TryHosting();

// Asks again at the end of this turn: the fork refuses while Chromium has
// no compositor view in the page window yet, and calling it inside the
// tracker's own update would re-enter that update.
void ScheduleHosting() {
  if (g_remote ? g_remote_attached : g_context != 0) return;
  if (g_hosting_scheduled || !g_browser) return;
  g_hosting_scheduled = true;
  CefPostTask(TID_UI, base::BindOnce(&TryHosting));
}

void TryHosting() {
  g_hosting_scheduled = false;
  if (g_remote) {
    // The fork refuses until cmux connected and Chromium made the page's
    // views::WebView; the next tracker read, load state or attach asks again.
    if (g_remote_attached || !g_browser || !g_remote_view || !g_rc_connected()) return;
    if (!g_set_remote_hosting(g_browser->GetIdentifier(), g_remote_view)) return;
    g_remote_attached = true;
    cmux_host::Header h;
    h.kind = cmux_host::kRemoteAttached;
    h.v[0] = 1;
    Send(h);
    DiagViews("attached");
    actprobe::Step("page_attached");
    return;
  }
  if (g_context || !g_browser || !g_set_layer_hosting) return;
  uint32_t id = g_set_layer_hosting(g_browser->GetIdentifier(), 1);
  if (!id) return;  // the next tracker read, load state or geometry asks again
  g_context = id;
  cmux_host::Header h;
  h.kind = cmux_host::kContext;
  h.v[0] = static_cast<int32_t>(id);
  Send(h);
}

}  // namespace

// The parent view of the page window. Its occlusion rect covers it, so the
// fork's tracker keeps the page window from taking the mouse (cmux forwards
// input); each tracker read retries a refused hosting request.
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
  ScheduleHosting();
  return nil;
}
@end

namespace {

void PlaceWindow() {
  if (!g_window) {
    g_window = [[NSWindow alloc] initWithContentRect:g_screen_rect
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    g_window.releasedWhenClosed = NO;
    g_window.opaque = NO;
    g_window.backgroundColor = NSColor.clearColor;
    g_window.hasShadow = NO;
    g_window.ignoresMouseEvents = YES;
    // Above normal windows on every macOS: on 14 and 15 Chromium reads the
    // window server's occlusion state, and a covered page window would make
    // the page hidden. It has no pixels and takes no clicks.
    g_window.level = NSFloatingWindowLevel;
    g_window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorIgnoresCycle |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary;
    g_parent = [[ChromiumHostParentView alloc] initWithFrame:NSMakeRect(0, 0, g_screen_rect.size.width,
                                                                         g_screen_rect.size.height)];
    g_parent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_window.contentView = g_parent;
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
                                                    object:g_window
                                                     queue:nil
                                                usingBlock:^(NSNotification*) { DiagViews("window_resize"); }];
    actprobe::Step("before_order_front");
    [g_window orderFrontRegardless];
    actprobe::Step("after_order_front");
  } else if (!NSEqualRects(g_window.frame, g_screen_rect)) {
    [g_window setFrame:g_screen_rect display:NO];
  }
}

// cef_event_flags_t as NSEventModifierFlags.
uint64_t NSFlags(uint32_t flags) {
  uint64_t ns = 0;
  if (flags & EVENTFLAG_CAPS_LOCK_ON) ns |= NSEventModifierFlagCapsLock;
  if (flags & EVENTFLAG_SHIFT_DOWN) ns |= NSEventModifierFlagShift;
  if (flags & EVENTFLAG_CONTROL_DOWN) ns |= NSEventModifierFlagControl;
  if (flags & EVENTFLAG_ALT_DOWN) ns |= NSEventModifierFlagOption;
  if (flags & EVENTFLAG_COMMAND_DOWN) ns |= NSEventModifierFlagCommand;
  if (flags & EVENTFLAG_IS_KEY_PAD) ns |= NSEventModifierFlagNumericPad;
  return ns;
}

class Client : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
               public CefRequestHandler, public CefKeyboardHandler {
 public:
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  // Remote Cocoa: a Command chord the page did not handle reached this
  // process (the page's view is cmux's, but the unhandled event comes back to
  // the browser process); cmux gives it to its own main menu.
  bool OnKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle) override {
    if (!g_remote || event.type != KEYEVENT_RAWKEYDOWN || !(event.modifiers & EVENTFLAG_COMMAND_DOWN)) return false;
    cmux_host::Header h;
    h.kind = cmux_host::kUnhandledKey;
    h.v[0] = event.native_key_code;
    h.flags = NSFlags(event.modifiers);
    h.ch = static_cast<uint16_t>(event.character);
    h.unmod = static_cast<uint16_t>(event.unmodified_character);
    h.t0 = Now();
    Send(h);
    return false;
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browser = browser;
    g_creating = false;
    actprobe::Step("page_created");
    ScheduleHosting();
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_browser = nullptr;
    CefQuitMessageLoop();
  }
  // A page's own popups and new windows stay out of this prototype.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& url, const CefString&,
                     WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Not inside Chromium's popup decision: on the next turn.
    CefPostTask(TID_UI, base::BindOnce([](std::string target) {
      if (g_browser) g_browser->GetMainFrame()->LoadURL(target);
    }, url.ToString()));
    return true;
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) SendText(cmux_host::kAddress, url.ToString());
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendText(cmux_host::kTitle, title.ToString());
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool, bool) override {
    actprobe::Step(loading ? "page_loading" : "page_loaded");
    ScheduleHosting();
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int, const CefString&) override {
    cmux_host::Header h;
    h.kind = cmux_host::kRendererGone;
    h.v[0] = static_cast<int32_t>(status);
    Send(h);
  }

 private:
  IMPLEMENT_REFCOUNTING(Client);
};

void CreateBrowserIfReady() {
  if (g_browser || g_creating || g_closing || g_pending_url.empty() || NSIsEmptyRect(g_screen_rect)) return;
  PlaceWindow();
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)g_parent,
                  CefRect(0, 0, static_cast<int>(g_screen_rect.size.width), static_cast<int>(g_screen_rect.size.height)));
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  // Chrome's status bubble would be a window of this process over cmux's
  // other panes; the host's page shows no hovered link.
  settings.chrome_status_bubble = STATE_DISABLED;
  actprobe::Step("before_create_browser");
  g_creating = CefBrowserHost::CreateBrowser(info, new Client(), g_pending_url, settings, nullptr, nullptr);
  actprobe::Step("after_create_browser");
  if (!g_creating) SendText(cmux_host::kError, "CreateBrowser refused");
}

// NSEventModifierFlags (and the pressed mouse buttons) as cef_event_flags_t.
uint32_t CefFlags(uint64_t ns, int buttons) {
  uint32_t flags = 0;
  if (ns & NSEventModifierFlagCapsLock) flags |= EVENTFLAG_CAPS_LOCK_ON;
  if (ns & NSEventModifierFlagShift) flags |= EVENTFLAG_SHIFT_DOWN;
  if (ns & NSEventModifierFlagControl) flags |= EVENTFLAG_CONTROL_DOWN;
  if (ns & NSEventModifierFlagOption) flags |= EVENTFLAG_ALT_DOWN;
  if (ns & NSEventModifierFlagCommand) flags |= EVENTFLAG_COMMAND_DOWN;
  if (ns & NSEventModifierFlagNumericPad) flags |= EVENTFLAG_IS_KEY_PAD;
  if (buttons & 1) flags |= EVENTFLAG_LEFT_MOUSE_BUTTON;
  if (buttons & 2) flags |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
  if (buttons & 4) flags |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
  return flags;
}

void RecordHop(uint64_t event_time) {
  const uint64_t now = Now();
  if (event_time && now > event_time) g_hop_us.push_back(static_cast<uint32_t>((now - event_time) / 1000));
}

// The modifier key a flags-changed key code belongs to.
uint64_t ModifierOfKey(int key_code) {
  switch (key_code) {
    case 56: case 60: return NSEventModifierFlagShift;
    case 59: case 62: return NSEventModifierFlagControl;
    case 58: case 61: return NSEventModifierFlagOption;
    case 55: case 54: return NSEventModifierFlagCommand;
    case 57: return NSEventModifierFlagCapsLock;
    default: return 0;
  }
}

void HandleKey(const cmux_host::Header& h) {
  CefKeyEvent event;
  event.native_key_code = h.v[1];
  event.modifiers = CefFlags(h.flags, 0);
  if (h.v[2]) event.modifiers |= EVENTFLAG_IS_REPEAT;
  CefRefPtr<CefBrowserHost> host = g_browser->GetHost();
  if (h.v[0] == 2) {
    // Flags changed: no characters, so CEF builds a flags-changed event.
    event.type = (h.flags & ModifierOfKey(h.v[1])) ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP;
    host->SendKeyEvent(event);
    return;
  }
  event.character = h.ch;
  event.unmodified_character = h.unmod;
  if (h.v[0] == 1) {
    event.type = KEYEVENT_KEYUP;
    host->SendKeyEvent(event);
    return;
  }
  event.type = KEYEVENT_RAWKEYDOWN;
  host->SendKeyEvent(event);
  // Text: a character that is not a function key (U+F700..U+F8FF) and no
  // Command chord, as cefclient's off-screen view sends it.
  const bool function_key = h.ch >= 0xF700 && h.ch <= 0xF8FF;
  if (h.ch && !function_key && !(h.flags & NSEventModifierFlagCommand)) {
    event.type = KEYEVENT_CHAR;
    host->SendKeyEvent(event);
  }
}

void HandleInput(const cmux_host::Header& h) {
  CefRefPtr<CefBrowserHost> host = g_browser->GetHost();
  CefMouseEvent mouse;
  mouse.x = h.v[0];
  mouse.y = h.v[1];
  switch (h.kind) {
    case cmux_host::kMouse: {
      mouse.modifiers = CefFlags(h.flags, h.v[5]);
      const auto button = h.v[3] == 2 ? MBT_RIGHT : h.v[3] == 1 ? MBT_MIDDLE : MBT_LEFT;
      if (h.v[2] == 0 || h.v[2] == 3) {
        host->SendMouseMoveEvent(mouse, h.v[2] == 3);
      } else {
        host->SendMouseClickEvent(mouse, button, h.v[2] == 2, std::max(1, h.v[4]));
      }
      break;
    }
    case cmux_host::kWheel:
      mouse.modifiers = CefFlags(h.flags, 0);
      host->SendMouseWheelEvent(mouse, h.v[2], h.v[3]);
      break;
    case cmux_host::kKey:
      HandleKey(h);
      break;
  }
  RecordHop(h.t0);
}

void SendStats() {
  std::vector<uint32_t> sorted = g_hop_us;
  std::sort(sorted.begin(), sorted.end());
  auto at = [&sorted](double q) -> int32_t {
    if (sorted.empty()) return 0;
    size_t index = std::min(sorted.size() - 1, static_cast<size_t>(q * static_cast<double>(sorted.size() - 1) + 0.5));
    return static_cast<int32_t>(sorted[index]);
  };
  cmux_host::Header h;
  h.kind = cmux_host::kStatsReply;
  h.v[0] = static_cast<int32_t>(sorted.size());
  h.v[1] = at(0.5);
  h.v[2] = at(0.95);
  h.v[3] = at(0.99);
  h.v[4] = sorted.empty() ? 0 : static_cast<int32_t>(sorted.back());
  h.v[5] = g_refused_frames;
  Send(h);
}

void HandleFrame(cmux_host::Header h, std::string payload) {
  switch (h.kind) {
    case cmux_host::kNavigate:
      g_pending_url = payload;
      if (g_browser) {
        g_browser->GetMainFrame()->LoadURL(payload);
      } else {
        CreateBrowserIfReady();
      }
      break;
    case cmux_host::kGeometry:
      g_screen_rect = NSMakeRect(h.v[2], h.v[3], std::max(1, h.v[0]), std::max(1, h.v[1]));
      if (g_window) PlaceWindow();
      CreateBrowserIfReady();
      ScheduleHosting();
      DiagViews("geometry");
      break;
    case cmux_host::kMouse:
    case cmux_host::kWheel:
    case cmux_host::kKey:
      if (g_browser && !g_remote) HandleInput(h);
      break;
    case cmux_host::kFocus:
      // Remote Cocoa: focus is the page's own view's in cmux's window (over mojo).
      if (g_browser && !g_remote) g_browser->GetHost()->SetFocus(h.v[0] != 0);
      break;
    case cmux_host::kAttach: {
      if (!g_remote) {
        ++g_refused_frames;
        break;
      }
      const uint64_t view = static_cast<uint64_t>(static_cast<uint32_t>(h.v[0])) |
                            (static_cast<uint64_t>(static_cast<uint32_t>(h.v[1])) << 32);
      if (view == g_remote_view) break;
      if (g_remote_attached && g_browser) {
        g_set_remote_hosting(g_browser->GetIdentifier(), 0);
        g_remote_attached = false;
        cmux_host::Header gone;
        gone.kind = cmux_host::kRemoteAttached;
        Send(gone);
      }
      g_remote_view = view;
      ScheduleHosting();
      break;
    }
    case cmux_host::kEdit:
      if (g_browser) {
        CefRefPtr<CefFrame> frame = g_browser->GetFocusedFrame();
        if (!frame) frame = g_browser->GetMainFrame();
        switch (h.v[0]) {
          case 0: frame->Copy(); break;
          case 1: frame->Cut(); break;
          case 2: frame->Paste(); break;
          case 3: frame->SelectAll(); break;
          case 4: frame->Undo(); break;
          case 5: frame->Redo(); break;
        }
      }
      break;
    case cmux_host::kPing: {
      cmux_host::Header pong;
      pong.kind = cmux_host::kPong;
      pong.t0 = h.t0;
      pong.t1 = Now();
      pong.seq = h.seq;
      Send(pong);
      break;
    }
    case cmux_host::kStats:
      SendStats();
      break;
    case cmux_host::kQuit:
      CloseHost();
      break;
    default:
      ++g_refused_frames;
      break;
  }
}

bool ReadAll(int fd, void* buffer, size_t length) {
  uint8_t* bytes = static_cast<uint8_t*>(buffer);
  size_t done = 0;
  while (done < length) {
    ssize_t n = read(fd, bytes + done, length - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    done += static_cast<size_t>(n);
  }
  return true;
}

// Blocking reads on a thread of its own; every frame runs on the UI thread.
void ReadWire(int fd) {
  for (;;) {
    uint8_t raw[cmux_host::kHeaderSize];
    cmux_host::Header h;
    if (!ReadAll(fd, raw, sizeof raw) || !cmux_host::Decode(raw, &h)) break;
    std::string payload(h.payload, '\0');
    if (h.payload && !ReadAll(fd, payload.data(), h.payload)) break;
    CefPostTask(TID_UI, base::BindOnce(&HandleFrame, h, std::move(payload)));
  }
  CefPostTask(TID_UI, base::BindOnce(&CloseHost));
}

// UI thread (cmux_rc_host_listen): cmux's remote_cocoa connection came or went.
void OnRemoteState(int connected, void*) {
  if (connected) {
    ScheduleHosting();
    return;
  }
  // The views cmux had are gone with the connection; a new connection
  // attaches the page again.
  if (g_remote_attached) {
    g_remote_attached = false;
    cmux_host::Header h;
    h.kind = cmux_host::kRemoteAttached;
    Send(h);
  }
}

class App : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit App(std::vector<std::string> switches) : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {
    cmux_shim::RegisterCustomSchemes(registrar);
  }

  void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    for (const std::string& name : cmux_shim::ApplySwitches(command_line, switches_)) {
      NSLog(@"cmux host: Chromium switch refused (weakens the sandbox): %s", name.c_str());
    }
  }

  void OnContextInitialized() override {
    actprobe::Step("context_initialized");
    cmux_host::Header ready;
    ready.kind = cmux_host::kReady;
    ready.v[0] = g_fork_api;
    ready.v[1] = static_cast<int32_t>(getpid());
    Send(ready);
    if (g_remote) {
      // Only cmux (this process's parent, which started it) may connect.
      char name[512] = {0};
      if (g_rc_listen(static_cast<int>(getppid()), &OnRemoteState, nullptr, name, sizeof name)) {
        SendText(cmux_host::kRemoteServer, name);
      } else {
        SendText(cmux_host::kError, "cmux_rc_host_listen refused");
      }
    }
    std::thread(ReadWire, kFromCmux).detach();
  }

 private:
  std::vector<std::string> switches_;
  IMPLEMENT_REFCOUNTING(App);
};

std::string Arg(const std::vector<std::string>& args, const std::string& name) {
  const std::string prefix = "--" + name + "=";
  for (const std::string& arg : args) {
    if (arg.rfind(prefix, 0) == 0) return arg.substr(prefix.size());
  }
  return std::string();
}

}  // namespace

int main(int argc, char* argv[]) {
  signal(SIGPIPE, SIG_IGN);
  std::vector<std::string> args(argv + 1, argv + argc);
  if (fcntl(kFromCmux, F_SETFD, FD_CLOEXEC) != 0 || fcntl(4, F_SETFD, FD_CLOEXEC) != 0) return 64;  // launched without the wire
  g_to_cmux = 4;
  std::vector<std::string> switches;
  for (const std::string& arg : args) {
    if (arg.rfind("--cef-switch=", 0) == 0) switches.push_back(arg.substr(13));
    if (arg == "--remote-cocoa") g_remote = true;
  }
  const std::string framework = Arg(args, "framework");
  const std::string binary = framework + "/Chromium Embedded Framework";

  @autoreleasepool {
    [ChromiumHostApplication sharedApplication];
    actprobe::Install();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    actprobe::Step("after_set_accessory");
  }
  // One thread so far: the framework's allocator and static initializers run
  // before any other thread exists (the race CmuxNextMallocZone removes in
  // the app cannot happen here).
  if (!cef_load_library(binary.c_str())) {
    SendText(cmux_host::kError, "cef_load_library failed: " + binary);
    return 65;
  }
  // The wrapper opens the framework RTLD_LOCAL, so its fork exports are not visible through RTLD_DEFAULT (every
  // lookup there came back null: fork API 0, exit 66, on the other Mac 2026-11-26). Reopen the same image by path, as
  // shim_process.mm's BindForkApi does; RTLD_NOLOAD returns the mapped image's handle without loading it again.
  void* const image = dlopen(binary.c_str(), RTLD_NOLOAD | RTLD_LAZY);
  if (!image) {
    SendText(cmux_host::kError, "the loaded Chromium framework has no handle: " + binary);
    return 65;
  }
  if (auto version = reinterpret_cast<int (*)()>(dlsym(image, "cmux_cef_api_version"))) g_fork_api = version();
  g_set_layer_hosting = reinterpret_cast<uint32_t (*)(int, int)>(dlsym(image, "cmux_browser_set_layer_hosting"));
  if (g_fork_api < 26 || !g_set_layer_hosting) {
    SendText(cmux_host::kError, "Chromium fork API " + std::to_string(g_fork_api) + " has no layer hosting (needs 26)");
    return 66;
  }
  if (g_remote) {
    g_rc_listen = reinterpret_cast<int (*)(int, void (*)(int, void*), void*, char*, int)>(
        dlsym(image, "cmux_rc_host_listen"));
    g_rc_connected = reinterpret_cast<int (*)()>(dlsym(image, "cmux_rc_host_connected"));
    g_set_remote_hosting =
        reinterpret_cast<int (*)(int, uint64_t)>(dlsym(image, "cmux_browser_set_remote_cocoa_hosting"));
    if (g_fork_api < 37 || !g_rc_listen || !g_rc_connected || !g_set_remote_hosting) {
      SendText(cmux_host::kError,
               "Chromium fork API " + std::to_string(g_fork_api) + " has no remote Cocoa pages (needs 37)");
      return 68;
    }
  }

  const std::string root = Arg(args, "root-cache");
  CefSettings settings;
  settings.no_sandbox = false;  // the helpers enter the sandbox themselves (helper_main.mm)
  settings.persist_session_cookies = false;
  CefString(&settings.framework_dir_path) = framework;
  // The app: the host runs from its Contents/MacOS (embed-cef.sh), so the helpers' sandbox (BUNDLE_PATH, the browser
  // process's main bundle) covers the framework and the helpers, as it does for the in-process engine.
  CefString(&settings.main_bundle_path) = [[[NSBundle mainBundle] bundlePath] UTF8String];
  CefString(&settings.browser_subprocess_path) = Arg(args, "subprocess");
  CefString(&settings.root_cache_path) = root;
  CefString(&settings.cache_path) = root + "/Profile";
  const std::string log_file = Arg(args, "log-file");
  if (!log_file.empty()) CefString(&settings.log_file) = log_file;

  CefMainArgs main_args(0, nullptr);
  if (!CefInitialize(main_args, settings, new App(std::move(switches)), nullptr)) {
    SendText(cmux_host::kError, "CefInitialize failed");
    return 67;
  }
  actprobe::Step("after_cef_initialize");
  CefRunMessageLoop();
  if (g_window) [g_window close];
  CefShutdown();
  return 0;
}
