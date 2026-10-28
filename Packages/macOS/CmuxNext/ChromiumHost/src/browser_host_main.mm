// cmux Chromium Host (plans/cmux-next/chrome-parity/p01-process.md 3.1-3.4).
//
// Chromium's browser process in its own app, so a CHECK or crash in it ends
// only this process, and its message loop runs on this process's main
// thread, never on cmux's. The host links the real shim (CEFShim/src/shim_*.mm)
// and runs every `cmux_shim_*` call cmux makes, sent over the control channel
// (chromium_host_control.h) and dispatched by the generated cases
// (host_dispatch.h). Like Chrome's browser main (content/browser/
// browser_main_loop.cc), it runs CefRunMessageLoop itself: no external pump.
//
// Launched by cmux with the control socket on fd 3:
//   <host> --framework=<CEF framework dir> [--input-doorbell=<name>]
// With --input-doorbell, fd 5 holds the input ring (chromium_host_input_ring.h): keys, clicks,
// pointer moves and wheel ticks, dispatched on Chromium's user-input queue and acked there
// (host_input.h).
// Order on the wire: each side's HELLO (the host's after the fork
// capabilities' MIRRORs); cmux's queued preinit ops, applied in order; INITIALIZE, which runs
// cmux_shim_initialize (CefInitialize) with an event_fn that forwards each
// event; then every other op. Control messages and input frames meet in one
// ordered stream (cmux_host::control::OrderedStream, task 092): an input frame
// waits for the control message it names, an ordered control message (focus,
// activation, geometry, IME, edit) for the input frame it follows, as Chrome's
// one RenderWidgetHostNSViewHost pipe orders them. The channel's end (cmux quit or crashed), or
// a shutdown op, closes every browser and ends the loop; a host that has
// not ended kQuitLimitSeconds after that _exits, so a hung UI thread or a
// hung CefInitialize never leaves an orphaned host behind.
//
// Energy Saver: this process is the page's browser process, so the saver's
// browser-side work runs here, as Chrome's BatterySaverModeManager runs it in
// its browser process (host_energy_saver.h). cmux's Chromium switches come in
// INITIALIZE, the set the app runs in process with (CEFSwitches); the host
// fits them to its own message loop and adds TimerSlackMac (host_switches.h).
//
// No window of the host is ever on screen: from
// initialize on, every Chromium widget of a detached page is blocked by the
// fork and dismissed here, a permission prompt held unanswered
// (host_blocked_widgets.h), and a host window that
// still shows (a window-modal sheet, an AppKit panel) is ordered out and
// logged (ObserveHostWindows).
//
// App Nap: no window of the host is on screen, so macOS may nap it. The host
// holds a user-initiated activity while cmux shows one of its pages, latency
// critical too while cmux is the active app, and lets App Nap apply when cmux
// is hidden or every page is (host_page_activity.h).
// Its main thread runs user-interactive.
//
// Hangs: each turn of the main run loop is a hang watch scope
// (host_hang_watcher.h). A turn of 250 ms or more goes
// to cmux's hang reports, one still running at 10 s gets a dump without
// crashing, and the input a turn dispatched is acked at its end, so cmux
// shows "Chromium is busy" when the UI thread takes no input for 2 s.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_task.h"

#include "chromium_host_control.h"
#include "chromium_host_input_ring.h"
#include "chromium_host_wire.h"
#include "cmux_cef_shim.h"
#include "host_blocked_widgets.h"
#include "host_dispatch.h"
#include "host_hang_watcher.h"
#include "host_input.h"
#include "host_page_activity.h"
#include "host_provider_link.h"
#include "host_switches.h"
#include "host_user_input.h"
#include "shim_internal.h"

// The wire's copies of CEF's event flags (chromium_host_wire.h, CefModifiersOf).
static_assert(cmux_host::kCefCapsLockOn == EVENTFLAG_CAPS_LOCK_ON && cmux_host::kCefShiftDown == EVENTFLAG_SHIFT_DOWN,
              "CEF's caps lock and shift flags");
static_assert(cmux_host::kCefControlDown == EVENTFLAG_CONTROL_DOWN && cmux_host::kCefAltDown == EVENTFLAG_ALT_DOWN &&
                  cmux_host::kCefCommandDown == EVENTFLAG_COMMAND_DOWN,
              "CEF's control, option and command flags");
static_assert(cmux_host::kCefPrecisionScrollingDelta == EVENTFLAG_PRECISION_SCROLLING_DELTA,
              "CEF's precise wheel delta flag");

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
// The host has cmux's bundle id, so a Quit by bundle id (the Dock, an
// AppleEvent) can reach it instead of cmux (chromium-host-bench.py ae_quit,
// cmux20-bench 2026-10-25: the host ended, cmux did not). A quit is cmux's to
// make: pass it to the app that started this host; the host then reads EOF
// and ends. With no such app (cmux is gone) the host ends as at EOF.
- (void)terminate:(id)sender {
  NSRunningApplication* parent = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
  if (parent && parent.processIdentifier != getpid() && parent.processIdentifier > 1) {
    [parent terminate];
    return;
  }
  [super terminate:sender];
}
@end

namespace {

constexpr int kControlFd = 3;
// A host that ran ends with this when a control message broke the wire's
// rules (host_dispatch.h, bad_message). Not a start failure
// (chromium_host_wire.h, kExit*): the supervisor's restart budget applies.
constexpr int kExitBadMessage = 68;

// Gives an activation of the host back to the app that started it: a plain
// [NSApp deactivate] left the host frontmost (cmux20-bench 2026-10-25: frontmost
// for 10 of 10 clicks after one activation), because macOS picks the next app
// itself. The host is the active app here, so it may hand activation over.
void ReturnActivationToParent() {
  NSRunningApplication* parent = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
  if (!parent || parent.processIdentifier == getpid() || parent.processIdentifier <= 1) {
    [NSApp deactivate];
    return;
  }
  if (@available(macOS 14.0, *)) {
    [NSApp yieldActivationToApplication:parent];
    [parent activateFromApplication:NSRunningApplication.currentApplication options:0];
  } else {
    [parent activateWithOptions:0];
  }
}

// Ends the process kQuitLimitSeconds after the first call, if it has not
// ended by then. Any thread.
std::atomic<bool> g_quit_deadline_armed{false};
void ArmQuitDeadline() {
  if (g_quit_deadline_armed.exchange(true)) return;
  std::thread([] {
    // wakeup-allow: deadline the quit's one hard deadline, armed once when the quit starts; the process ends at it
    std::this_thread::sleep_for(std::chrono::seconds(cmux_host::kQuitLimitSeconds));
    _exit(0);  // no atexit handlers or destructors: they could wait on the hung thread
  }).detach();
}

// Runs `task` on the main thread, in post order, before CefInitialize (the
// host waits for INITIALIZE in CFRunLoopRun) and after it (CefRunMessageLoop
// runs the same run loop): one FIFO for the host's life keeps cmux's order
// across the start, which CefPostTask(TID_UI) cannot before Chromium's UI
// thread exists. Any thread.
void PostToMain(std::function<void()> task) {
  CFRunLoopRef main = CFRunLoopGetMain();
  CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
    @autoreleasepool {
      task();
    }
  });
  CFRunLoopWakeUp(main);
}

// The fork's input calls (host_user_input.h), looked up
// once at start; nullptr when the fork does not have one.
struct ForkInputCalls {
  cmux_host::PostTaskFn post_user_input_task = nullptr;  // API 30
  cmux_host::SetEventTimeFn set_input_event_time = nullptr;  // a fork item after API 31
  cmux_host::SetWheelAckHandlerFn set_wheel_ack_handler = nullptr;  // a fork item after API 31 (host_wheel_ack.h)
};

// After cmux_shim_load. The CEF wrapper opened the framework RTLD_LOCAL, so
// its exports are not in RTLD_DEFAULT: open the loaded image again by path,
// as the shim's BindForkApi does.
ForkInputCalls ResolveForkInputCalls(const std::string& framework_binary) {
  ForkInputCalls calls;
  void* image = dlopen(framework_binary.c_str(), RTLD_NOLOAD | RTLD_LAZY);
  if (!image) return calls;
  calls.post_user_input_task =
      reinterpret_cast<cmux_host::PostTaskFn>(dlsym(image, "cmux_post_user_input_task"));
  calls.set_input_event_time =
      reinterpret_cast<cmux_host::SetEventTimeFn>(dlsym(image, "cmux_set_input_event_time"));
  calls.set_wheel_ack_handler =
      reinterpret_cast<cmux_host::SetWheelAckHandlerFn>(dlsym(image, "cmux_set_wheel_ack_handler"));
  return calls;
}

// The fork's blocked widget calls (fork API 31, host_blocked_widgets.h),
// looked up as ResolveForkInputCalls does; nullptr below API 31.
struct ForkBlockedWidgetCalls {
  cmux_host::SetBlockedWidgetHandlerFn set_handler = nullptr;
  cmux_host::BlockedWidgetCloseFn close = nullptr;
};

ForkBlockedWidgetCalls ResolveForkBlockedWidgetCalls(const std::string& framework_binary) {
  ForkBlockedWidgetCalls calls;
  void* image = dlopen(framework_binary.c_str(), RTLD_NOLOAD | RTLD_LAZY);
  if (!image) return calls;
  calls.set_handler =
      reinterpret_cast<cmux_host::SetBlockedWidgetHandlerFn>(dlsym(image, "cmux_set_blocked_widget_handler"));
  calls.close = reinterpret_cast<cmux_host::BlockedWidgetCloseFn>(dlsym(image, "cmux_blocked_widget_close"));
  return calls;
}

// One line of the host's log (its stderr: cmux's app log).
void HostLog(const std::string& line) {
  fprintf(stderr, "cmux-chromium-host: %s\n", line.c_str());
}

// A task for CefPostTask(TID_UI): the default UI queue, for a fork without
// the user-input queue. A task CEF refuses or drops is freed unrun.
class UITask : public CefTask {
 public:
  explicit UITask(std::function<void()> task) : task_(std::move(task)) {}
  void Execute() override { task_(); }

 private:
  std::function<void()> task_;
  IMPLEMENT_REFCOUNTING(UITask);
};

// The fork's user-input queue as an InputTasks queue; empty when the fork
// does not have it.
cmux_host::InputTasks::Queue UserInputQueue(cmux_host::PostTaskFn post_user_input_task) {
  if (!post_user_input_task) return cmux_host::InputTasks::Queue();
  return [post_user_input_task](std::function<void()> task) {
    cmux_host::PostThrough(post_user_input_task, std::move(task));
  };
}
// CefPostTask(TID_UI), the default UI queue: InputTasks' fallback.
void PostDefaultUITask(std::function<void()> task) {
  CefPostTask(TID_UI, new UITask(std::move(task)));
}

// The NSEvent clock of a frame's t0 (chromium_host_wire.h), now.
uint64_t UptimeNowNs() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

std::string Arg(const std::vector<std::string>& args, const std::string& name) {
  const std::string prefix = "--" + name + "=";
  for (const std::string& arg : args) {
    if (arg.rfind(prefix, 0) == 0) return arg.substr(prefix.size());
  }
  return std::string();
}

// The Crashpad database in the host's data folder (`--root-cache`); ChromiumHostConfiguration.crashDatabase
// names the same folder for cmux, which reads the dumps.
constexpr char kCrashDatabase[] = "Crashpad";

// Puts this host's crash dumps (its own and its helpers') into `<root cache>/Crashpad`. CEF starts Chromium's
// Crashpad handler in CefInitialize when the app bundle holds crash_reporter.cfg (embed-cef.sh puts it there with
// the host; no ServerURL, so no dump leaves this Mac), as Chrome does in components/crash/core/app/crashpad_mac.mm,
// and takes the database folder from BREAKPAD_DUMP_LOCATION (CefCrashReporterClient::GetCrashDumpLocation).
// Before any other thread starts: setenv races a thread that reads the environment.
void SetCrashDumpLocation(const std::string& root_cache) {
  if (root_cache.empty()) return;
  const std::string database = root_cache + "/" + kCrashDatabase;
  @autoreleasepool {
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:@(database.c_str())
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions : @0700}
                                                       error:&error]) {
      fprintf(stderr, "cmux-chromium-host: no crash dump folder: %s\n", error.localizedDescription.UTF8String ?: "");
      return;
    }
  }
  setenv("BREAKPAD_DUMP_LOCATION", database.c_str(), 1);
}

// A kWheel frame to its page, with its scroll phase,
// momentum phase and precise flag through the fork's wheel call, so
// Chromium's MouseWheelPhaseHandler latches the gesture and hands the
// momentum to the page as Chrome does with the NSEvent. Both paths get pixel
// deltas (WheelOf). A fork without the call (below API 30) gets
// CefBrowserHost::SendMouseWheelEvent with whole pixels, the fraction carried
// to the next frame, and no phases; a frame with no whole pixel (a phase edge)
// is not sent there, as WebMouseWheelEventBuilder's note on zero-tick wheels
// asks. UI thread.
void SendWheel(cmux_host::HostContext& host, cmux_host::WheelPixelCarry& carry, const cmux_host::Header& frame) {
  const int browser_id = host.Browser(cmux_host::input_ring::BrowserOf(frame));
  const cmux_host::Wheel wheel = cmux_host::WheelOf(frame);
  if (cmux_shim_browser_send_wheel(browser_id, wheel.x, wheel.y, wheel.dx, wheel.dy, wheel.precise ? 1 : 0,
                                   wheel.phase, wheel.momentum_phase, wheel.modifiers)) {
    // The fork's ack of this wheel goes back as WHEEL_ACK with its seq.
    host.WheelSent(browser_id, frame.seq, wheel.momentum_phase != cmux_host::kWheelPhaseNone);
    return;
  }
  CefRefPtr<CefBrowser> browser = cmux_shim::BrowserById(browser_id);
  const cmux_host::WheelPixels pixels = carry.Take(browser_id, frame);
  if (!browser || (pixels.dx == 0 && pixels.dy == 0)) return;
  CefMouseEvent event;
  event.x = static_cast<int>(wheel.x);
  event.y = static_cast<int>(wheel.y);
  const int precise = wheel.precise ? cmux_host::kCefPrecisionScrollingDelta : 0;
  event.modifiers = static_cast<uint32_t>(wheel.modifiers | precise);
  browser->GetHost()->SendMouseWheelEvent(event, pixels.dx, pixels.dy);
}

// One input ring frame, in the ordered stream's order, with its NSEvent's
// time as the event time Chromium sees (EventTimeOf).
// A page's geometry moves its page view only when it changed, in this order,
// so a click after a resize hits the resized page (HostContext::PlaceFrame,
// task 053); wheels go to Chromium here, keys, clicks, moves and Edit
// commands through DispatchInputFrame (host_input.mm).
void DispatchInput(cmux_host::HostContext& host, cmux_host::WheelPixelCarry& carry,
                   cmux_host::SetEventTimeFn set_event_time, const cmux_host::Header& frame) {
  if (host.PlaceFrame(frame)) return;
  const cmux_host::ScopedEventTime event_time(set_event_time, cmux_host::EventTimeOf(frame, UptimeNowNs()));
  if (frame.kind == cmux_host::kWheel) {
    SendWheel(host, carry, frame);
    return;
  }
  cmux_host::DispatchInputFrame(host.Browser(cmux_host::input_ring::BrowserOf(frame)), frame);
}

}  // namespace

// Runs main-thread work at the start of the main display's next frame
// (TextInputPushes::RequestFrame), as ExternalBeginFrameSourceMac drives
// Chrome's BeginFrames from the display link
// (components/viz/service/frame_sinks/external_begin_frame_source_mac.cc).
// The link is paused while no work waits, as Chrome stops BeginFrames no
// client needs; a screen change makes a new link for the next request.
// Main thread only.
@interface ChromiumHostFrameClock : NSObject
- (void)requestFrame:(std::function<void()>)task;
- (void)invalidate;
@end

@implementation ChromiumHostFrameClock {
  CADisplayLink* _link;  // retained; retains this clock until -invalidate
  std::vector<std::function<void()>> _waiting;
  id _screenObserver;
}

- (instancetype)init {
  if ((self = [super init])) {
    // The block retains this clock until -invalidate removes the observer.
    _screenObserver = [[NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                  [self dropLink];
                }] retain];
  }
  return self;
}

- (void)requestFrame:(std::function<void()>)task {
  _waiting.push_back(std::move(task));
  if (!_link) {
    NSScreen* screen = NSScreen.mainScreen;
    if (!screen) {
      [self tick:nil];  // no display: no frame to wait for
      return;
    }
    _link = [[screen displayLinkWithTarget:self selector:@selector(tick:)] retain];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
  _link.paused = NO;
}

- (void)tick:(CADisplayLink*)link {
  _link.paused = YES;
  std::vector<std::function<void()>> tasks;
  tasks.swap(_waiting);
  for (auto& task : tasks) task();
}

- (void)dropLink {
  [_link invalidate];
  [_link release];
  _link = nil;
  if (!_waiting.empty()) {
    std::vector<std::function<void()>> tasks;
    tasks.swap(_waiting);
    for (auto& task : tasks) [self requestFrame:std::move(task)];
  }
}

- (void)invalidate {
  if (_screenObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_screenObserver];
    [_screenObserver release];
    _screenObserver = nil;
  }
  _waiting.clear();
  [_link invalidate];
  [_link release];
  _link = nil;
}
@end

namespace {

// A symbol of the shim linked into this executable (an optional export), or nullptr.
void* ResolveShimSymbol(const char* name) {
  return dlsym(RTLD_DEFAULT, name);
}

// The host's main thread state: what HostContext asks for (HostDelegate).
// Main thread only.
class HostMain : public cmux_host::HostDelegate {
 public:
  void Initialize(cmux_host::InitializeRequest request) override {
    request_ = std::move(request);
    CFRunLoopStop(CFRunLoopGetMain());
  }

  void Quit() override {
    ArmQuitDeadline();
    if (!running_) {
      quit_before_start_ = true;
      CFRunLoopStop(CFRunLoopGetMain());
      return;
    }
    if (quitting_) return;
    quitting_ = true;
    cmux_shim_close_all();  // BEFORE_CLOSE for each browser, then BrowserClosed
    BrowserClosed();
  }

  void BrowserClosed() override {
    if (quitting_ && !loop_quit_ && cmux_shim_live_browser_count() == 0) {
      loop_quit_ = true;
      CefQuitMessageLoop();
    }
  }

  void BadMessage(const std::string& what) override {
    fprintf(stderr, "cmux-chromium-host: bad message from cmux: %s\n", what.c_str());
    exit_status_ = kExitBadMessage;
    Quit();
  }

  std::optional<cmux_host::InitializeRequest>& request() { return request_; }
  bool quit_before_start() const { return quit_before_start_; }
  void set_running() { running_ = true; }
  int exit_status() const { return exit_status_; }

 private:
  std::optional<cmux_host::InitializeRequest> request_;
  bool running_ = false;  // CefInitialize returned
  bool quit_before_start_ = false;
  bool quitting_ = false;
  bool loop_quit_ = false;
  int exit_status_ = 0;
};

// The backstop for a host window that shows although the fork blocks
// Chromium's widgets: a window-modal sheet, which
// AppKit's -beginSheet: shows outside headless mode, or an AppKit panel. A
// window ordered in with alpha above 0 is taken off screen (a sheet ended
// through its parent, as its own Escape would, so Chromium's completion
// handler closes the widget) and logged as UNEXPECTED_WINDOW. The host's own
// page windows are never ordered in, and Chromium's detached page windows
// have alpha 0. Main thread.
void TakeOffScreen(NSWindow* window) {
  if (!window || !window.isVisible || window.alphaValue <= 0) return;
  NSWindow* parent = window.sheetParent;
  const char* title = window.title.UTF8String;
  HostLog(cmux_host::UnexpectedWindowLine(object_getClassName(window), title ? title : "", parent != nil));
  if (parent) {
    [parent endSheet:window];
  } else {
    [window orderOut:nil];
  }
}

// AppKit posts nothing when a window is ordered in: occlusion changes only
// for a window nothing covers, and the host, never the active app, orders
// its windows in behind cmux's, where they stay occluded and never become
// key. So every time the main run loop is about to wait, in every mode
// (Chromium's tasks, menu tracking, a modal session), the host checks its
// windows: an ordered-in window is off screen again before the run loop
// sleeps, at most one pass after it came. A sheet or panel that takes the
// keyboard is also caught as it becomes key (ObserveActivation).
void ObserveHostWindows() {
  CFRunLoopObserverRef idle = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
        @autoreleasepool {
          for (NSWindow* window in NSApp.windows) TakeOffScreen(window);
        }
      });
  CFRunLoopAddObserver(CFRunLoopGetMain(), idle, kCFRunLoopCommonModes);
  CFRelease(idle);
}

void ObserveActivation() {
  // The host shares cmux's bundle id and is never the app a person uses:
  // if anything activates it (a click or an accessibility focus on a page
  // window, which Chromium owns), give the activation straight back.
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSApplicationDidBecomeActiveNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification*) {
                    ReturnActivationToParent();
                  }];
  [center addObserverForName:NSWindowDidBecomeKeyNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification*) {
                    // Which window: for the host log (cmux's stderr), so the source can be removed.
                    NSWindow* key = NSApp.keyWindow;
                    fprintf(stderr, "cmux-chromium-host: a window became key: %s\n",
                            key ? object_getClassName(key) : "none");
                    TakeOffScreen(key);
                    ReturnActivationToParent();
                  }];
}

// The activity that keeps App Nap off the host (PageShowActivity's hold): as
// Chrome's AppNapActivity (content/common/mac/app_nap_activity.mm), user
// initiated with idle system sleep allowed, so a shown page draws at the
// display's rate and the Mac may still sleep; latency critical too while cmux
// is the active app. A change of level begins the new activity before it ends
// the old one, so App Nap never applies between. Main thread.
class AppNapActivity {
 public:
  AppNapActivity() = default;
  AppNapActivity(const AppNapActivity&) = delete;
  AppNapActivity& operator=(const AppNapActivity&) = delete;
  ~AppNapActivity() { Hold(cmux_host::ActivityLevel::kNone); }

  void Hold(cmux_host::ActivityLevel level) {
    if (level == level_) return;
    @autoreleasepool {
      id<NSObject> previous = token_;
      token_ = nil;
      if (level != cmux_host::ActivityLevel::kNone) {
        NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep;
        if (level == cmux_host::ActivityLevel::kActive) options |= NSActivityLatencyCritical;
        NSString* reason = level == cmux_host::ActivityLevel::kActive ? @"cmux is the active app"
                                                                       : @"cmux shows a Chromium page";
        token_ = [[NSProcessInfo.processInfo beginActivityWithOptions:options reason:reason] retain];
      }
      if (previous) {
        [NSProcessInfo.processInfo endActivity:previous];
        [previous release];
      }
      level_ = level;
    }
  }

 private:
  id<NSObject> token_ = nil;
  cmux_host::ActivityLevel level_ = cmux_host::ActivityLevel::kNone;
};

// cmux's active and hidden state, from macOS: NSWorkspace posts every app's
// activate, deactivate, hide and unhide, and the host keeps those of its
// parent (cmux, which spawned it). The parent's NSRunningApplication gives the
// state at the start; after that each notification names the change itself,
// since the running application's own properties update later. Main thread;
// the observers end with this object.
class ParentAppObserver {
 public:
  explicit ParentAppObserver(cmux_host::PageShowActivity& activity) : activity_(activity) {
    @autoreleasepool {
      NSRunningApplication* parent = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
      // A parent that is gone (the host now belongs to launchd) is neither active nor hidden.
      if (parent && parent.processIdentifier != getpid() && parent.processIdentifier > 1) {
        active_ = parent.active;
        hidden_ = parent.hidden;
      }
      Observe(NSWorkspaceDidActivateApplicationNotification, &active_, true);
      Observe(NSWorkspaceDidDeactivateApplicationNotification, &active_, false);
      Observe(NSWorkspaceDidHideApplicationNotification, &hidden_, true);
      Observe(NSWorkspaceDidUnhideApplicationNotification, &hidden_, false);
      activity_.SetApp(active_, hidden_);
    }
  }
  ParentAppObserver(const ParentAppObserver&) = delete;
  ParentAppObserver& operator=(const ParentAppObserver&) = delete;
  ~ParentAppObserver() {
    @autoreleasepool {
      NSNotificationCenter* center = NSWorkspace.sharedWorkspace.notificationCenter;
      for (id<NSObject> token : tokens_) {
        [center removeObserver:token];
        [token release];
      }
    }
  }

 private:
  // On `name` for the parent, `*field` becomes `value`.
  void Observe(NSNotificationName name, bool* field, bool value) {
    id<NSObject> token = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:name
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                  NSRunningApplication* app = note.userInfo[NSWorkspaceApplicationKey];
                  if (app.processIdentifier != getppid()) return;
                  *field = value;
                  activity_.SetApp(active_, hidden_);
                }];
    tokens_.push_back([token retain]);
  }

  cmux_host::PageShowActivity& activity_;
  bool active_ = false;
  bool hidden_ = false;
  std::vector<id<NSObject>> tokens_;
};

}  // namespace

int main(int argc, char* argv[]) {
  // The host's main thread is Chromium's UI thread, which draws and takes
  // input for the page a person looks at: user-interactive, as Chrome's
  // display-critical threads (base/threading/platform_thread_apple.mm). cmux
  // spawns the host with no QoS clamp (ChromiumHostLauncher.priority).
  if (const int qos = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); qos != 0) {
    fprintf(stderr, "cmux-chromium-host: main thread QoS not set: %d\n", qos);
  }
  signal(SIGPIPE, SIG_IGN);
  std::vector<std::string> args(argv + 1, argv + argc);
  struct stat control_stat;
  if (fstat(kControlFd, &control_stat) != 0 || !S_ISSOCK(control_stat.st_mode) ||
      fcntl(kControlFd, F_SETFD, FD_CLOEXEC) != 0) {
    return cmux_host::kExitNoWire;  // launched without the control socket
  }
  const std::string framework = Arg(args, "framework");
  const std::string binary = framework + "/Chromium Embedded Framework";
  SetCrashDumpLocation(Arg(args, "root-cache"));
  // The input ring and its doorbell, checked in before the HELLO, when cmux passed them.
  const std::string doorbell_name = Arg(args, "input-doorbell");
  void* ring = nullptr;
  cmux_host::input_ring::MachDoorbell doorbell;
  if (!doorbell_name.empty()) {
    ring = cmux_host::input_ring::MapRegion(cmux_host::input_ring::kRingFd);
    if (ring == nullptr || !doorbell.CheckIn(doorbell_name.c_str())) {
      fprintf(stderr, "cmux-chromium-host: the input ring or its doorbell %s cannot be used\n", doorbell_name.c_str());
      return cmux_host::kExitNoWire;
    }
  }

  @autoreleasepool {
    [ChromiumHostApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ObserveActivation();
    ObserveHostWindows();
  }
  // Held from here, through Chromium's start, until the first shown page
  // count after initialize (HostContext::Resume); then while cmux is active
  // or shows a page. Each change of level goes to the host log.
  AppNapActivity app_nap;
  cmux_host::PageShowActivity page_activity([&app_nap](const cmux_host::ActivityState& state) {
    app_nap.Hold(state.level);
    fputs(cmux_host::ActivityLogLine(state).c_str(), stderr);
  });
  // One thread so far: the framework's allocator and static initializers run
  // before any other thread exists. cmux_shim_load also binds the fork API.
  char error[512] = {0};
  if (!cmux_shim_load(binary.c_str(), error, sizeof error)) {
    fprintf(stderr, "cmux-chromium-host: %s\n", error);
    return cmux_host::kExitFrameworkLoad;
  }
  const int fork_api = cmux_shim_fork_api_version();
  if (fork_api < cmux_host::kMinForkAPI) {
    fprintf(stderr, "cmux-chromium-host: Chromium fork API %d is older than the host needs (%d)\n", fork_api,
            cmux_host::kMinForkAPI);
    return cmux_host::kExitForkAPI;
  }
  const ForkInputCalls fork_input = ResolveForkInputCalls(binary);
  const ForkBlockedWidgetCalls fork_blocked = ResolveForkBlockedWidgetCalls(binary);
  if (!cmux_shim_prepare_application()) {
    fprintf(stderr, "cmux-chromium-host: NSApp does not implement CefAppProtocol\n");
    return cmux_host::kExitInitialize;
  }
  // The host's page windows never show (each is detached, HostPageViews):
  // each page's cursor goes to the page view in cmux (CMUX_SHIM_CURSOR), as
  // Chrome's browser process sends it to the app shim's view
  // (RenderWidgetHostViewMac::DisplayCursor).
  cmux_shim_set_cursor_events(1);

  HostMain host_main;
  cmux_host::HostPageViews page_views;
  std::unique_ptr<cmux_host::control::Channel> channel;
  // The browser host's provider link (host_provider_link.h); made with its relays below.
  std::unique_ptr<cmux_host::ProviderLink> provider_link;
  // Outlives `host`, whose text input flushes it runs.
  struct FrameClock {
    ChromiumHostFrameClock* clock = [[ChromiumHostFrameClock alloc] init];
    ~FrameClock() {
      [clock invalidate];
      [clock release];
    }
  } frame_clock;
  cmux_host::HostContext host(
      [&channel](const cmux_host::control::Message& message) { return channel && channel->Send(message); },
      host_main, page_views, &ResolveShimSymbol,
      [clock = frame_clock.clock](std::function<void()> task) { [clock requestFrame:std::move(task)]; });
  // The resize fence's inbox, checked in before the HELLO so cmux finds it
  // when it looks the name up after (host_resize.h); none without the
  // argument, and every resize goes unfenced.
  const std::unique_ptr<cmux_host::FenceInbox> fence_inbox =
      cmux_host::CheckInFenceInbox(Arg(args, cmux_host::kResizeFenceSwitch));
  cmux_host::PageResizes page_resizes(fence_inbox.get(), &cmux_shim_browser_set_resize_fence);
  host.SetPageResizes(&page_resizes);
  // cmux_shim_load bound the fork's cmux_cef_set_energy_saver when it has
  // it; without it the HELLO lists no saver and kOpEnergySaver changes nothing.
  if (cmux_shim::fork_api().set_energy_saver) host.SetEnergySaver(&cmux_shim_set_energy_saver);
  // The fork's lock delegate (API 31, task 227): cmux locks its own cursor and keys for the page
  // (host_locks.h, task 229); without it the HELLO lists no locks and cmux asks for none.
  if (cmux_shim::fork_api().set_lock_handler) host.SetLockHandler(&cmux_shim_set_lock_handler);
  host.SetPageShowActivity(&page_activity);
  // After the framework load, which must run before any other thread exists:
  // NSWorkspace's notifications may start one.
  ParentAppObserver parent_app(page_activity);
  // The UI thread's turns from here on, and its watcher thread; the HELLO
  // says the host acks dispatched input and reports its hangs.
  cmux_host::hang::HostHangWatch hang_watch(
      [&channel](const cmux_host::control::Message& message) { return channel && channel->Send(message); });
  host.SetHangWatch(true);
  // Agent CDP from the browser host straight to the pages here:
  // the link's frames reach this thread in batches, and
  // what the pages answer goes back on the link's writer, never through cmux.
  cmux_host::AgentRelays agent_relays(cmux_host::AgentRelays::Calls{
      [&host](int32_t client) { return host.Browser(client); },
      [](int browser, const char* message) { return cmux_shim_devtools_send(browser, message); },
      [](int browser, int enabled) { cmux_shim_devtools_watch_events(browser, enabled); },
      [&provider_link](std::string json) { provider_link->Write(std::move(json)); }});
  provider_link = std::make_unique<cmux_host::ProviderLink>(
      &PostToMain,
      [&agent_relays](std::vector<cmux_host::RelayFrame> frames) {
        for (const cmux_host::RelayFrame& frame : frames) agent_relays.OnFrame(frame);
      },
      [&agent_relays] { agent_relays.LinkEnded(); }, &cmux_host::ProviderLinkPeerSignedAsCmux);
  host.SetProviderLink(&agent_relays, [&agent_relays, &provider_link](
                                          const cmux_host::ProviderLinkConfig& config) {
    if (provider_link->Dials(config)) return;  // the same browser host: the link and its relays stay
    agent_relays.LinkEnded();
    provider_link->Connect(config);
  });
  // Main thread only, like `host`. Ring frames (task 041) go in through
  // `ordered_input` and are dispatched (DispatchInput), then acked, only when
  // the stream lets them run (task 042 on 092's barrier): each paced move or
  // wheel tick by kOpInputAck (host_input.h), and each ordered input frame by
  // the hang watch at the end of its turn (the host's ack is its dispatch,
  // p01-process.md 3.1); a kPing's or kStats' seq is its request id and is
  // never acked.
  cmux_host::WheelPixelCarry wheel_carry;
  cmux_host::control::OrderedStream ordered(
      [&host](std::vector<cmux_host::control::Message> messages) { host.OnMessages(std::move(messages)); });
  cmux_host::OrderedInput ordered_input(
      ordered,
      [&host, &wheel_carry, &hang_watch, set_event_time = fork_input.set_input_event_time](
          const cmux_host::Header& frame) {
        DispatchInput(host, wheel_carry, set_event_time, frame);
        hang_watch.FrameDispatched(frame);
      },
      [&channel](cmux_host::control::Message acks) {
        if (channel) channel->Send(acks);
      },
      [&host_main](const char* what) { host_main.BadMessage(what ? what : "the ordered input stream"); });
  // The host's one input queue (host_user_input.h): Chromium's user-input
  // queue, or CefPostTask(TID_UI) on a fork without it, chosen here once; the
  // main run loop until CefInitialize returned. HostInput's Post (below).
  cmux_host::InputTasks input_tasks(UserInputQueue(fork_input.post_user_input_task), &PostDefaultUITask,
                                    &PostToMain);
  using HostInput = cmux_host::input_ring::HostInput<cmux_host::input_ring::MachDoorbell>;
  std::unique_ptr<HostInput> input;
  // Each control batch or the input's opening may let held frames run, and a
  // batch the stream took in part is offered again (the rest waited in the
  // ring meanwhile).
  auto after = [&ordered_input, &input](cmux_host::control::OrderedStream::Result result) {
    ordered_input.After(result);
    if (input) input->Retry();
  };
  // The reader thread starts here, after the framework load.
  channel = std::make_unique<cmux_host::control::Channel>(
      kControlFd, &PostToMain,
      [&ordered, &after](std::vector<cmux_host::control::Message> messages) {
        after(ordered.AddControl(std::move(messages)));
      },
      [&host_main](cmux_host::control::End) { host_main.Quit(); });

  // The input reader starts here too, after the framework load. Frames that
  // come before initialize wait in the stream (input opens after Resume). Its
  // batches go through InputTasks: the main run loop until CefInitialize
  // returned, then the queue chosen at start; a refused batch is dropped and
  // keeps the BatchGate shut until Stop (host_user_input.h).
  if (ring != nullptr) {
    input = std::make_unique<HostInput>(ring, doorbell);
    input->Start(
        [&input_tasks](std::function<void()> task) { input_tasks.Post(std::move(task)); },
        [&ordered_input](const HostInput::Frames& frames, size_t from) { return ordered_input.Take(frames, from); },
        [&host_main](cmux_host::input_ring::Reader::End end) {
          if (end == cmux_host::input_ring::Reader::End::kBroken) {
            host_main.BadMessage("input ring: a position or a frame no writer makes");
            return;
          }
          fprintf(stderr, "cmux-chromium-host: the input doorbell failed; no input can arrive\n");
          host_main.Quit();
        });
  }
  // Chromium's ack of each wheel goes to cmux's swipe navigation (WHEEL_ACK).
  host.SetWheelAckHandler(fork_input.set_wheel_ack_handler);
  // Each helper's end goes to cmux's debug.crashes (HELPER_EXIT). Declared after
  // `host`, so the watch stops before `host` goes; started once initialize returned.
  cmux_host::HelperExitWatcher helper_exits([&host](const cmux_host::HelperExit& ended) {
    PostToMain([&host, ended] { host.HelperExited(ended); });
  });
  host.Attach();

  // Preinit ops apply as they arrive; INITIALIZE (or the channel's end) stops
  // this loop. A run loop with no source returns at once, so a no-op source
  // keeps it waiting, as MessagePumpCFRunLoop's work source does
  // (base/message_loop/message_pump_apple.mm).
  CFRunLoopSourceContext keep_alive_context = {};
  keep_alive_context.perform = [](void*) {};
  CFRunLoopSourceRef keep_alive = CFRunLoopSourceCreate(nullptr, 0, &keep_alive_context);
  CFRunLoopAddSource(CFRunLoopGetMain(), keep_alive, kCFRunLoopCommonModes);
  CFRunLoopRun();
  CFRunLoopRemoveSource(CFRunLoopGetMain(), keep_alive, kCFRunLoopCommonModes);
  CFRelease(keep_alive);
  // Chromium's widgets of detached pages, from initialize on: each is
  // dismissed in a UI task after its report and logged. Outlives
  // cmux_shim_shutdown, so a dismissal posted during shutdown finds it.
  cmux_host::BlockedWidgets blocked_widgets(
      [close = fork_blocked.close](int widget_id) { return close ? close(widget_id) : 0; }, &PostDefaultUITask,
      &HostLog);
  int status = host_main.exit_status();
  if (!host_main.quit_before_start() && host_main.request()) {
    const cmux_host::InitializeRequest& request = *host_main.request();
    const std::vector<std::string> host_switches = cmux_host::HostSwitches(request.switches);
    std::vector<const char*> switches;
    for (const std::string& entry : host_switches) switches.push_back(entry.c_str());
    switches.push_back(nullptr);
    auto c_str = [](const std::optional<std::string>& value) { return value ? value->c_str() : nullptr; };
    // cmux's runtime sends no paths in host mode (CEFRuntimeBoot.chromiumPaths): the app's
    // bundle and helper come from the spawn's arguments (ChromiumHostConfiguration), so
    // Chromium never takes this small host bundle as its main bundle.
    const std::string main_bundle =
        request.main_bundle_path.empty() ? Arg(args, "main-bundle") : request.main_bundle_path;
    const std::string subprocess = request.subprocess_path.empty() ? Arg(args, "subprocess") : request.subprocess_path;
    const std::string log_file = cmux_host::HostLogFile(request.log_file, Arg(args, "log-file"));
    // The framework this host loaded at start; cmux names the same directory.
    // No schedule_fn: the shim then runs without an external pump, and
    // CefRunMessageLoop below is the loop.
    const int ok = cmux_shim_initialize(framework.c_str(), main_bundle.c_str(),
                                        subprocess.c_str(), request.root_cache_path.c_str(),
                                        log_file.empty() ? nullptr : log_file.c_str(), request.log_severity, c_str(request.locale),
                                        c_str(request.accept_languages), switches.data(), &host, nullptr,
                                        &cmux_host::HostContext::OnShimEvent, nullptr);
    if (!ok) {
      fprintf(stderr, "cmux-chromium-host: CefInitialize failed\n");
      channel->Close();
      return cmux_host::kExitInitialize;
    }
    // One line of the host's own after Chromium's start, so a crashed host's log tail (ChromiumHostSupervisor) says it
    // got past CefInitialize and on which fork, even when Chromium logged nothing at cmux's severity (warnings and up).
    if (!log_file.empty()) {
      if (FILE* log = fopen(log_file.c_str(), "a")) {
        fprintf(log, "cmux-chromium-host: Chromium started, pid %d, fork API %d\n", getpid(), fork_api);
        fclose(log);
      }
    }
    host_main.set_running();
    // Before Resume runs cmux's first op, so before any page is detached.
    if (!blocked_widgets.Install(fork_blocked.set_handler)) {
      HostLog("no blocked widget handler (fork API " + std::to_string(fork_api) +
              "): Chromium's own widgets of a page can show");
    }
    input_tasks.Start();
    PostToMain([&host, &ordered, &after, &helper_exits] {
      host.Resume();
      after(ordered.OpenInput());  // the messages that waited for initialize ran first
      helper_exits.Start();  // after the INITIALIZE ack: no HELPER_EXIT reaches cmux before it
    });
    CefRunMessageLoop();
    if (input) input->Stop();  // no batch runs after this, so none reaches a shut down Chromium
    hang_watch.Stop();         // before Chromium shuts down: no dump of its shutdown
    channel->Close();
    provider_link->Close();  // the browser host relays through cmux again
    cmux_shim_shutdown();
    status = host_main.exit_status();
  } else {
    channel->Close();
  }
  input.reset();
  cmux_host::input_ring::UnmapRegion(ring);
  return status;
}
