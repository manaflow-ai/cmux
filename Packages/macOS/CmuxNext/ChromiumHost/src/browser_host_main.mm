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

#import <AppKit/AppKit.h>
#include <dlfcn.h>
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
      break;
    case cmux_host::kMouse:
    case cmux_host::kWheel:
    case cmux_host::kKey:
      if (g_browser) HandleInput(h);
      break;
    case cmux_host::kFocus:
      if (g_browser) g_browser->GetHost()->SetFocus(h.v[0] != 0);
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
  }
  const std::string framework = Arg(args, "framework");
  const std::string binary = framework + "/Chromium Embedded Framework";

  @autoreleasepool {
    [ChromiumHostApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  }
  // One thread so far: the framework's allocator and static initializers run
  // before any other thread exists (the race CmuxNextMallocZone removes in
  // the app cannot happen here).
  if (!cef_load_library(binary.c_str())) {
    SendText(cmux_host::kError, "cef_load_library failed: " + binary);
    return 65;
  }
  if (auto version = reinterpret_cast<int (*)()>(dlsym(RTLD_DEFAULT, "cmux_cef_api_version"))) g_fork_api = version();
  g_set_layer_hosting = reinterpret_cast<uint32_t (*)(int, int)>(dlsym(RTLD_DEFAULT, "cmux_browser_set_layer_hosting"));
  if (g_fork_api < 26 || !g_set_layer_hosting) {
    SendText(cmux_host::kError, "Chromium fork API " + std::to_string(g_fork_api) + " has no layer hosting (needs 26)");
    return 66;
  }

  const std::string root = Arg(args, "root-cache");
  CefSettings settings;
  settings.no_sandbox = false;  // the helpers enter the sandbox themselves (helper_main.mm)
  settings.persist_session_cookies = false;
  CefString(&settings.framework_dir_path) = framework;
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
  CefRunMessageLoop();
  if (g_window) [g_window close];
  CefShutdown();
  return 0;
}
