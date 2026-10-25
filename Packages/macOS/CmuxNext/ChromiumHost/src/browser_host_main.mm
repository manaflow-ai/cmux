// cmux Chromium host (prototype; plans/cmux-next/cef-helper-app-DESIGN.md).
//
// Chromium's browser process in its own app, so a CHECK or crash in it ends
// only this process, and its message pump runs on this process's main thread,
// never on cmux's. One Chrome-style page per host. The page draws into a Core
// Animation context (cmux_browser_set_layer_hosting; the host needs fork API
// kMinForkAPI) whose id goes to cmux, which shows it in a pane with a
// CALayerHost. cmux forwards mouse and key events over the wire
// (chromium_host_wire.h); they reach Chromium through
// CefBrowserHost::Send*Event.
//
// The page window sits in a transparent, click-through window of this
// process at the pane's screen rect. Its parent view has alpha 0 for its whole
// life: before hosting Chromium draws into it, and once hosted the page's
// layers live in the context, so this window never shows pixels over other
// apps (it floats on every Space), even when the fork drops the context. The
// parent view's occlusion rect (the fork's -cmuxOcclusionRects) covers it, so
// the fork's tracker never lets it take the mouse.
//
// Launched by cmux (ChromiumHostLauncher) with the wire on fd 3 (frames from cmux) and fd 4 (frames to cmux):
//   <host> --framework=<CEF framework dir> --subprocess=<base helper exe>
//          --main-bundle=<cmux.app> --root-cache=<dir> [--log-file=<path>]
//          [--cef-switch=<name[=value]>]...
// EOF on fd 3 (cmux quit or crashed) closes the page and ends the host; the
// wire is read from before CefInitialize, and a host that has not ended
// kQuitLimitSeconds after EOF or kQuit _exits, so a hung UI thread or a hung
// CefInitialize never leaves an orphaned host behind.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_values.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#include "chromium_host_wire.h"
#include "command_line_switches.h"
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

// The host's own window (the page window's parent): never key or main, so a
// click or an accessibility focus on it cannot activate the host. Input comes
// from cmux over the wire.
@interface ChromiumHostWindow : NSWindow
@end

@implementation ChromiumHostWindow
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

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
// The host input hops of the last kHopWindow events (a ring), and how many in all.
constexpr size_t kHopWindow = 8192;
std::vector<uint32_t> g_hop_us;
size_t g_hop_next = 0;
uint64_t g_hop_events = 0;
int g_refused_frames = 0;
// Times the host became the active app, and times one of its windows (its
// own, or Chromium's page window, a child of it) became key. Each one is
// undone at once ([NSApp deactivate]); both stay 0 when nothing activates the
// host (kStatsReply t0).
uint32_t g_activations = 0;
uint32_t g_key_windows = 0;
// The focus cmux last sent (kFocus), applied when the browser exists.
bool g_page_focused = false;

// Ends the process kQuitLimitSeconds after the first call, if it has not
// ended by then. Any thread: the reader arms it at EOF, the UI thread at kQuit.
std::atomic<bool> g_quit_deadline_armed{false};
void ArmQuitDeadline() {
  if (g_quit_deadline_armed.exchange(true)) return;
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(cmux_host::kQuitLimitSeconds));
    _exit(0);  // no atexit handlers or destructors: they could wait on the hung thread
  }).detach();
}

// Frames the reader has read and the UI thread has not run (also those read
// before Chromium's UI thread exists, while CefInitialize runs). The
// posted-task queue has no limit of its own: this one is bounded (pointer
// moves, wheel deltas and geometry coalesce; keys and clicks are kept), so a
// hung UI thread can neither grow the host's memory without end nor hide
// from cmux that it stopped reading.
cmux_host::FrameQueue g_frames(cmux_host::kFrameBacklog);

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

void CloseHost() {
  ArmQuitDeadline();
  if (g_closing) return;
  g_closing = true;
  if (g_browser) {
    g_browser->GetHost()->CloseBrowser(true);  // OnBeforeClose quits the loop
  } else if (!g_creating) {
    CefQuitMessageLoop();
  }
  // else: a browser is being created; OnAfterCreated closes it, and its
  // OnBeforeClose quits the loop (CefShutdown never runs with a live browser).
}

void TryHosting();
void SetPageFocused(bool focused);

// Asks again at the end of this turn: the fork refuses while Chromium has
// no compositor view in the page window yet, and calling it inside the
// tracker's own update would re-enter that update.
void ScheduleHosting() {
  if (g_context || g_hosting_scheduled || !g_browser) return;
  g_hosting_scheduled = true;
  CefPostTask(TID_UI, base::BindOnce(&TryHosting));
}

void TryHosting() {
  g_hosting_scheduled = false;
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
  // Each tracker read: Chromium's page window (a child of the host's window)
  // takes no mouse either; input comes from cmux over the wire.
  for (NSWindow* child in self.window.childWindows) child.ignoresMouseEvents = YES;
  ScheduleHosting();
  return nil;
}
@end

namespace {

void PlaceWindow() {
  if (!g_window) {
    g_window = [[ChromiumHostWindow alloc] initWithContentRect:g_screen_rect
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
    // No pixels, ever: until cmux_browser_set_layer_hosting gives a context
    // (and again if the fork drops it), Chromium draws into this window,
    // which floats above every app on every Space; once hosted, the page's
    // layers are in the context, which cmux shows. A view's alpha, not the
    // window's, so the window server's occlusion state (which Chromium reads)
    // stays visible.
    g_parent.alphaValue = 0;
    g_window.contentView = g_parent;
    [g_window orderFrontRegardless];
  } else if (!NSEqualRects(g_window.frame, g_screen_rect)) {
    [g_window setFrame:g_screen_rect display:NO];
  }
}

class Client : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
               public CefRequestHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browser = browser;
    g_creating = false;
    if (g_closing) {
      // kQuit or EOF came while the browser was being created (CloseHost).
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    if (g_page_focused) SetPageFocused(true);
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
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool, bool, bool) override { ScheduleHosting(); }
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
  g_creating = CefBrowserHost::CreateBrowser(info, new Client(), g_pending_url, settings, nullptr, nullptr);
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
  if (!event_time || now <= event_time) return;
  const uint32_t hop = static_cast<uint32_t>((now - event_time) / 1000);
  ++g_hop_events;
  if (g_hop_us.size() < kHopWindow) {
    g_hop_us.push_back(hop);
  } else {
    g_hop_us[g_hop_next] = hop;
    g_hop_next = (g_hop_next + 1) % kHopWindow;
  }
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

// The page's focus, with no window or app activation. CefBrowserHost::SetFocus
// cannot be used: in this windowed Chrome-style mode it activates the page's
// widget (browser_platform_delegate_chrome_child_window.cc SetFocus ->
// Widget::Activate -> NativeWidgetNSWindowBridge kShowAndActivateWindow ->
// [NSApp activateIgnoringOtherApps:YES] + makeKeyAndOrderFront), which made
// the host, an app with cmux's bundle id, the active app and took cmux's key
// window. DevTools focus emulation makes the page behave as focused (focus
// events, document.hasFocus(), a caret, text input) while its window stays
// inactive; keys arrive over the wire either way.
void SetPageFocused(bool focused) {
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetBool("enabled", focused);
  g_browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setFocusEmulationEnabled", params);
}

void SendStats(uint32_t seq) {
  std::vector<uint32_t> sorted = g_hop_us;
  std::sort(sorted.begin(), sorted.end());
  auto at = [&sorted](double q) -> int32_t {
    if (sorted.empty()) return 0;
    size_t index = std::min(sorted.size() - 1, static_cast<size_t>(q * static_cast<double>(sorted.size() - 1) + 0.5));
    return static_cast<int32_t>(sorted[index]);
  };
  cmux_host::Header h;
  h.kind = cmux_host::kStatsReply;
  h.seq = seq;
  h.v[0] = static_cast<int32_t>(std::min<uint64_t>(g_hop_events, INT32_MAX));
  h.v[1] = at(0.5);
  h.v[2] = at(0.95);
  h.v[3] = at(0.99);
  h.v[4] = sorted.empty() ? 0 : static_cast<int32_t>(sorted.back());
  h.v[5] = g_refused_frames;
  h.t1 = g_frames.coalesced();
  h.t0 = (static_cast<uint64_t>(g_activations) << 32) | g_key_windows;
  Send(h);
}

void HandleFrame(cmux_host::Header h, std::string payload) {
  switch (h.kind) {
    case cmux_host::kNavigate:
      if (g_closing) break;
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
      break;
    case cmux_host::kMouse:
    case cmux_host::kWheel:
    case cmux_host::kKey:
      if (g_browser) HandleInput(h);
      break;
    case cmux_host::kFocus:
      g_page_focused = h.v[0] != 0;
      if (g_browser) SetPageFocused(g_page_focused);  // else OnAfterCreated applies it
      break;
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
      SendStats(h.seq);
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

// One posted task per batch: runs every waiting frame in the order read.
void DrainFrames() {
  for (cmux_host::QueuedFrame& frame : g_frames.Take()) HandleFrame(frame.header, std::move(frame.payload));
}

void Post(cmux_host::FrameQueue::Push push) {
  if (push == cmux_host::FrameQueue::Push::kWake) CefPostTask(TID_UI, base::BindOnce(&DrainFrames));
}

// Blocking reads on a thread of its own, from before CefInitialize; every
// frame runs on the UI thread, in a batch (g_frames). More than kFrameBacklog
// waiting frames after coalescing means the UI thread hangs: the reader stops
// reading and ends the host as at EOF. cmux's writes then fill the socket and
// cmux ends the host too (ChromiumHostConnection.sendBuffer).
void ReadWire(int fd) {
  for (;;) {
    uint8_t raw[cmux_host::kHeaderSize];
    cmux_host::Header h;
    if (!ReadAll(fd, raw, sizeof raw) || !cmux_host::Decode(raw, &h)) break;
    std::string payload(h.payload, '\0');
    if (h.payload && !ReadAll(fd, payload.data(), h.payload)) break;
    const cmux_host::FrameQueue::Push push = g_frames.Add(h, std::move(payload));
    if (push == cmux_host::FrameQueue::Push::kFull) break;  // the UI thread hangs: end as at EOF
    Post(push);
  }
  // EOF (cmux quit or died) or a broken wire: end within the quit limit,
  // even when the UI thread or CefInitialize never gets to it. The quit runs
  // after every waiting frame, once the UI thread exists.
  ArmQuitDeadline();
  Post(g_frames.AddEnd());
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
    for (const std::string& entry : switches_) {
      size_t eq = entry.find('=');
      if (eq == std::string::npos) {
        command_line->AppendSwitch(entry);
        continue;
      }
      const std::string name = entry.substr(0, eq);
      std::string value = entry.substr(eq + 1);
      if (cmux_shim::IsFeatureListSwitch(name) && command_line->HasSwitch(name)) {
        value = cmux_shim::MergeFeatureList(command_line->GetSwitchValue(name).ToString(), value);
      }
      command_line->AppendSwitchWithValue(name, value);
    }
  }

  void OnContextInitialized() override {
    cmux_host::Header ready;
    ready.kind = cmux_host::kReady;
    ready.v[0] = g_fork_api;
    ready.v[1] = static_cast<int32_t>(getpid());
    Send(ready);
    // The frames read so far (and an EOF meanwhile) run in one batch.
    if (g_frames.MarkReady()) CefPostTask(TID_UI, base::BindOnce(&DrainFrames));
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
  if (fcntl(kFromCmux, F_SETFD, FD_CLOEXEC) != 0 || fcntl(4, F_SETFD, FD_CLOEXEC) != 0) {
    return cmux_host::kExitNoWire;  // launched without the wire
  }
  g_to_cmux = 4;
  std::vector<std::string> switches;
  for (const std::string& arg : args) {
    if (arg.rfind("--cef-switch=", 0) == 0) switches.push_back(arg.substr(13));
  }
  const std::string framework = Arg(args, "framework");
  const std::string binary = framework + "/Chromium Embedded Framework";

  @autoreleasepool {
    [ChromiumHostApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // The host shares cmux's bundle id and is never the app a person uses:
    // if anything activates it (a click or an accessibility focus on the
    // page window, which Chromium owns), give the activation straight back.
    // On the main thread (Chromium's UI thread), like the counters.
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                      ++g_activations;
                      [NSApp deactivate];
                    }];
    [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                      ++g_key_windows;
                      [NSApp deactivate];
                    }];
  }
  // One thread so far: the framework's allocator and static initializers run
  // before any other thread exists (the race CmuxNextMallocZone removes in
  // the app cannot happen here).
  if (!cef_load_library(binary.c_str())) {
    SendText(cmux_host::kError, "cef_load_library failed: " + binary);
    return cmux_host::kExitFrameworkLoad;
  }
  // cef_load_library opens the framework RTLD_LOCAL, so its fork exports are not
  // visible through RTLD_DEFAULT: reopen the same image by path (as the shim's
  // BindForkApi does). RTLD_DEFAULT read API 0 and every host exited kExitForkAPI.
  if (void* image = dlopen(binary.c_str(), RTLD_NOLOAD | RTLD_LAZY)) {
    if (auto version = reinterpret_cast<int (*)()>(dlsym(image, "cmux_cef_api_version"))) g_fork_api = version();
    g_set_layer_hosting = reinterpret_cast<uint32_t (*)(int, int)>(dlsym(image, "cmux_browser_set_layer_hosting"));
  }
  if (g_fork_api < cmux_host::kMinForkAPI || !g_set_layer_hosting) {
    SendText(cmux_host::kError, "Chromium fork API " + std::to_string(g_fork_api) + " is older than the host needs (" +
                                    std::to_string(cmux_host::kMinForkAPI) + ": layer hosting and resize sync)");
    return cmux_host::kExitForkAPI;
  }
  // Reads the wire from here (after the framework load, which needs this to
  // be the only thread), so EOF ends a host even while CefInitialize hangs.
  std::thread(ReadWire, kFromCmux).detach();

  const std::string root = Arg(args, "root-cache");
  CefSettings settings;
  settings.no_sandbox = false;  // the helpers enter the sandbox themselves (helper_main.mm)
  settings.persist_session_cookies = false;
  CefString(&settings.framework_dir_path) = framework;
  // The app the host is nested in (cmux.app), as in process: its bundle holds
  // the framework and the helpers that Chromium starts and sandboxes. With the
  // host's own small bundle here the page's renderer ended at once and the
  // host aborted (SIGABRT in CrBrowserMain, twice, cmuxs-Mac-mini-3, macOS 27,
  // 2026-10-24); the remote browser host failed the same way while its main
  // bundle did not hold its helpers (7d2aa0ed900: "GPU process isn't usable").
  std::string main_bundle = Arg(args, "main-bundle");
  if (main_bundle.empty()) main_bundle = [[[NSBundle mainBundle] bundlePath] UTF8String];
  CefString(&settings.main_bundle_path) = main_bundle;
  CefString(&settings.browser_subprocess_path) = Arg(args, "subprocess");
  CefString(&settings.root_cache_path) = root;
  CefString(&settings.cache_path) = root + "/Profile";
  const std::string log_file = Arg(args, "log-file");
  if (!log_file.empty()) {
    CefString(&settings.log_file) = log_file;
    settings.log_severity = LOGSEVERITY_WARNING;  // FATAL and CHECK messages, not every INFO line
  }

  CefMainArgs main_args(0, nullptr);
  if (!CefInitialize(main_args, settings, new App(std::move(switches)), nullptr)) {
    SendText(cmux_host::kError, "CefInitialize failed");
    return cmux_host::kExitInitialize;
  }
  CefRunMessageLoop();
  if (g_window) [g_window close];
  CefShutdown();
  return 0;
}
