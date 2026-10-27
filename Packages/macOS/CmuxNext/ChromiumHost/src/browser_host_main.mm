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
//   <host> --framework=<CEF framework dir>
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
// App Nap: no window of the host is on screen, so macOS may nap it. The host
// holds a user-initiated activity while cmux shows one of its pages and lets
// App Nap apply when every page is hidden (host_page_activity.h, task
// p14-energy-128).

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
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
#include "host_dispatch.h"
#include "host_page_activity.h"
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

// The fork's input calls (host_user_input.h, task p04-input-065), looked up
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

// A kWheel frame to its page (task p04-input-063), with its scroll phase,
// momentum phase and precise flag through the fork's wheel call, so
// Chromium's MouseWheelPhaseHandler latches the gesture and hands the
// momentum to the page as Chrome does with the NSEvent. Both paths get pixel
// deltas (WheelOf). A fork without the call (below API 30) gets
// CefBrowserHost::SendMouseWheelEvent with whole pixels, the fraction carried
// to the next frame, and no phases; a frame with no whole pixel (a phase edge)
// is not sent there, as WebMouseWheelEventBuilder's note on zero-tick wheels
// asks. UI thread.
void SendWheel(cmux_host::HostContext& host, cmux_host::WheelPixelCarry& carry, const cmux_host::Header& frame) {
  const int browser_id = host.Browser(cmux_host::BrowserOf(frame));
  const cmux_host::Wheel wheel = cmux_host::WheelOf(frame);
  if (cmux_shim_browser_send_wheel(browser_id, wheel.x, wheel.y, wheel.dx, wheel.dy, wheel.precise ? 1 : 0,
                                   wheel.phase, wheel.momentum_phase, wheel.modifiers)) {
    // The fork's ack of this wheel goes back as WHEEL_ACK with its seq (task p01-process-234).
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
// time as the event time Chromium sees (EventTimeOf, task p04-input-065).
// A page's geometry moves its page view only when it changed, in this order,
// so a click after a resize hits the resized page (HostContext::PlaceFrame,
// task 053); wheels go to Chromium here; task p01-process-042 adds the other
// kinds with the ring's reader, and until it starts the reader no frame comes.
void DispatchInput(cmux_host::HostContext& host, cmux_host::WheelPixelCarry& carry,
                   cmux_host::SetEventTimeFn set_event_time, const cmux_host::Header& frame) {
  if (host.PlaceFrame(frame)) return;
  const cmux_host::ScopedEventTime event_time(set_event_time, cmux_host::EventTimeOf(frame, UptimeNowNs()));
  if (frame.kind == cmux_host::kWheel) SendWheel(host, carry, frame);
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
                    ReturnActivationToParent();
                  }];
}

// The activity that keeps App Nap off the host (PageShowActivity's hold): as
// Chrome's AppNapActivity (content/common/mac/app_nap_activity.mm), user
// initiated with idle system sleep allowed, so a shown page draws at the
// display's rate and the Mac may still sleep. Main thread.
class AppNapActivity {
 public:
  AppNapActivity() = default;
  AppNapActivity(const AppNapActivity&) = delete;
  AppNapActivity& operator=(const AppNapActivity&) = delete;
  ~AppNapActivity() { Hold(false); }

  void Hold(bool held) {
    if (held == (token_ != nil)) return;
    @autoreleasepool {
      if (held) {
        token_ = [[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                reason:@"cmux shows a Chromium page"] retain];
      } else {
        [NSProcessInfo.processInfo endActivity:token_];
        [token_ release];
        token_ = nil;
      }
    }
  }

 private:
  id<NSObject> token_ = nil;
};

}  // namespace

int main(int argc, char* argv[]) {
  signal(SIGPIPE, SIG_IGN);
  std::vector<std::string> args(argv + 1, argv + argc);
  struct stat control_stat;
  if (fstat(kControlFd, &control_stat) != 0 || !S_ISSOCK(control_stat.st_mode) ||
      fcntl(kControlFd, F_SETFD, FD_CLOEXEC) != 0) {
    return cmux_host::kExitNoWire;  // launched without the control socket
  }
  const std::string framework = Arg(args, "framework");
  const std::string binary = framework + "/Chromium Embedded Framework";

  @autoreleasepool {
    [ChromiumHostApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ObserveActivation();
  }
  // Held from here, through Chromium's start, until the first shown page
  // count after initialize (HostContext::Resume).
  AppNapActivity app_nap;
  cmux_host::PageShowActivity page_activity([&app_nap](bool held) { app_nap.Hold(held); });
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
  // cmux_shim_load bound the fork's cmux_cef_set_energy_saver (p14-energy-029) when it has
  // it; without it the HELLO lists no saver and kOpEnergySaver changes nothing.
  if (cmux_shim::fork_api().set_energy_saver) host.SetEnergySaver(&cmux_shim_set_energy_saver);
  host.SetPageShowActivity(&page_activity);
  // Main thread only, like `host`. The input ring (task 041) attaches its
  // dispatch here (AttachInput) and hands each frame to AddInput; until then
  // no frame comes and cmux stamps no ordered op with an input seq.
  cmux_host::WheelPixelCarry wheel_carry;
  cmux_host::control::OrderedStream ordered(
      [&host](std::vector<cmux_host::control::Message> messages) { host.OnMessages(std::move(messages)); });
  ordered.AttachInput([&host, &wheel_carry, set_event_time = fork_input.set_input_event_time](
                          const cmux_host::Header& frame) { DispatchInput(host, wheel_carry, set_event_time, frame); });
  // The host's one input queue (host_user_input.h): Chromium's user-input
  // queue, or CefPostTask(TID_UI) on a fork without it, chosen here once; the
  // main run loop until CefInitialize returned. HostInput's Post when task
  // p01-process-042 starts the ring's reader:
  // `[&input_tasks](std::function<void()> task) { input_tasks.Post(std::move(task)); }`.
  cmux_host::InputTasks input_tasks(UserInputQueue(fork_input.post_user_input_task), &PostDefaultUITask,
                                    &PostToMain);
  auto check = [&host_main, &ordered](cmux_host::control::OrderedStream::Result result) {
    if (result == cmux_host::control::OrderedStream::Result::kMalformed) host_main.BadMessage(ordered.what());
  };
  // The reader thread starts here, after the framework load.
  channel = std::make_unique<cmux_host::control::Channel>(
      kControlFd, &PostToMain,
      [&ordered, &check](std::vector<cmux_host::control::Message> messages) {
        check(ordered.AddControl(std::move(messages)));
      },
      [&host_main](cmux_host::control::End) { host_main.Quit(); });
  // Chromium's ack of each wheel goes to cmux's swipe navigation (WHEEL_ACK, task p01-process-234).
  host.SetWheelAckHandler(fork_input.set_wheel_ack_handler);
  // Each helper's end goes to cmux's debug.crashes (HELPER_EXIT, task p01-process-225). Declared after
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
  int status = host_main.exit_status();
  if (!host_main.quit_before_start() && host_main.request()) {
    const cmux_host::InitializeRequest& request = *host_main.request();
    const std::vector<std::string> host_switches = cmux_host::HostSwitches(request.switches);
    std::vector<const char*> switches;
    for (const std::string& entry : host_switches) switches.push_back(entry.c_str());
    switches.push_back(nullptr);
    auto c_str = [](const std::optional<std::string>& value) { return value ? value->c_str() : nullptr; };
    // The framework this host loaded at start; cmux names the same directory.
    // No schedule_fn: the shim then runs without an external pump, and
    // CefRunMessageLoop below is the loop.
    const int ok = cmux_shim_initialize(framework.c_str(), request.main_bundle_path.c_str(),
                                        request.subprocess_path.c_str(), request.root_cache_path.c_str(),
                                        c_str(request.log_file), request.log_severity, c_str(request.locale),
                                        c_str(request.accept_languages), switches.data(), &host, nullptr,
                                        &cmux_host::HostContext::OnShimEvent, nullptr);
    if (!ok) {
      fprintf(stderr, "cmux-chromium-host: CefInitialize failed\n");
      channel->Close();
      return cmux_host::kExitInitialize;
    }
    host_main.set_running();
    input_tasks.Start();
    PostToMain([&host, &ordered, &check, &helper_exits] {
      host.Resume();
      check(ordered.OpenInput());  // the messages that waited for initialize ran first
      helper_exits.Start();  // after the INITIALIZE ack: no HELPER_EXIT reaches cmux before it
    });
    CefRunMessageLoop();
    channel->Close();
    cmux_shim_shutdown();
    status = host_main.exit_status();
  } else {
    channel->Close();
  }
  return status;
}
