// The wire between cmux and the Chromium host app (prototype behind
// `browserHost.helper`; plans/cmux-next/cef-helper-app-DESIGN.md).
// Needs no CEF: scripts/cmux-next/tests/chromium-host-wire.test.sh compiles
// it alone. CmuxNextBrowser mirrors it in ChromiumHostFrame.swift; the golden
// bytes in ../tests/chromium_host_wire_test.cpp and
// ChromiumHostFrameTests.swift are the same. CI runs neither the C++ test nor
// this script (no new CI tests): whoever changes either side runs both.
//
// A frame is a 64-byte little-endian header and `payload` bytes after it
// (UTF-8 text: a URL, a title). Fields by kind are listed with each kind.
// Times are CLOCK_UPTIME_RAW nanoseconds, one clock for both processes.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>

namespace cmux_host {

inline constexpr size_t kHeaderSize = 64;
// Longer payloads end the connection: no kind carries more than a URL.
inline constexpr uint32_t kMaxPayload = 64 * 1024;
// Seconds a host may take to end after kQuit or EOF before it ends by force
// (it _exits itself; cmux SIGKILLs it): ChromiumHostFrame.quitLimit.
inline constexpr int kQuitLimitSeconds = 15;
// The oldest fork API the host runs on: detached hosting (30), so no page
// window of the host is ever on screen (its windows are never ordered in,
// HostPageViews), over layer hosting (26) and the resize sync (27), so its
// Chromium never holds a commit for a resize on its own. cmux starts it with
// the switch set of API 27 (ChromiumHostConfiguration,
// CEFSwitches.resizeSyncForkAPI: no AsyncLiveResize).
inline constexpr int kMinForkAPI = 30;
// Frames the reader may hand to the UI thread that it has not run yet (and
// frames held before the UI thread exists), after coalescing (FrameQueue):
// ChromiumHostConnection.frameBacklog.
inline constexpr size_t kFrameBacklog = 4096;

// Exit statuses of a host that could not start. cmux does not restart such a
// host (ChromiumHostExit.startFailures): a new one would fail the same way.
inline constexpr int kExitNoWire = 64;          // fds 3 and 4 are not open
inline constexpr int kExitFrameworkLoad = 65;   // cef_load_library failed
inline constexpr int kExitForkAPI = 66;         // fork API below kMinForkAPI
inline constexpr int kExitInitialize = 67;      // CefInitialize failed

enum Kind : uint32_t {
  // cmux -> host
  kNavigate = 1,   // payload url
  kGeometry = 2,   // v0 width, v1 height (points), v2 screen x, v3 screen y (bottom left), v4 scale * 1000
                   // (informational: the host's window takes the scale of the screen it is placed on;
                   // cmux sends the geometry again when the window moves or changes screen or scale)
  kMouse = 3,      // v0 x, v1 y (points, top left), v2 phase (0 move, 1 down, 2 up, 3 exit), v3 button
                   // (0 left, 1 middle, 2 right; ClickButtonOf below), v4 click count, v5 pressed buttons
                   // (bits 1 left, 2 right, 4 middle, 8 back, 16 forward: NSEvent.pressedMouseButtons and
                   // the DOM's MouseEvent.buttons), flags = NSEventModifierFlags, t0 event time. The back
                   // and forward buttons (NSEvent buttonNumber 3 and 4, Chrome's
                   // WebPointerProperties::Button::kBack and kForward) are not sent until the host can
                   // click them: CEF's SendMouseClickEvent has only left, middle, right
  kWheel = 4,      // v0 x, v1 y (points, top left), v2 v3 scrollingDeltaX/Y x kWheelDeltaScale, v4 phase, v5
                   // momentum phase (NSEventPhase bits), flags = NSEventModifierFlags | kWheelPrecise, t0
                   // (Wheel below)
  kKey = 5,        // v0 phase (0 down, 1 up, 2 flags changed), v1 key code, v2 repeat, flags, ch, unmod, t0;
                   // the host sends it with cmux_shim::SendHostKeyEvent and the frame's input seq, which
                   // KEY_UNHANDLED carries back for a chord the page leaves unhandled.
                   // v3 (ChromiumHostTextInput.KeyMark): on a down, 0 the key and ch,
                   // 1 an input method took it (VKEY_PROCESSKEY down, skip_if_unhandled, no char), 2 the
                   // char ch only; on an up, 1 the up of that process key (skip_if_unhandled)
  kFocus = 6,      // v0 1 focused, 0 not
  kPing = 7,       // t0 cmux send time; the host answers kPong
  kStats = 8,      // seq request id (never an input seq: not an IsOrderedInput kind); the host answers
                   // kStatsReply with the same seq
  kQuit = 9,
  kEdit = 10,      // v0 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo
  kIme = 11,       // one text input op of the page view's NSTextInputClient (ChromiumHostTextInputOp,
                   // p01-process-043), in order with the key frames around it: v0 op (0 set composition,
                   // 1 commit text, 2 finish composing, 3 cancel composition, 4 edit commands for the next
                   // key down, 5 an edit command with no key), v1 v2 the selection in the text (op 0),
                   // v3 v4 the field range the text replaces (ops 0 and 1; -1 -1 none), v5 clause count
                   // (op 0); payload the text as UTF-16LE (ops 4 and 5: the command names joined by
                   // '\n'), then per clause i32 start, i32 end, u32 color 0xAARRGGBB, u32 thick (0 or 1).
                   // It has a payload, so it never rides the input ring.
  kTextInputWatch = 12,  // v0 1: push kTextInputState after each change; 0: stop (task 044's watch)
  kGesture = 13,   // a trackpad gesture of the page view, the input that
                   // RenderWidgetHostNSViewHost takes as PinchEvent and SmartMagnifyEvent
                   // (content/common/render_widget_host_ns_view.mojom; render_widget_host_view_cocoa.mm
                   // -magnifyWithEvent:, -smartMagnifyWithEvent:) and the Force Touch pressure that
                   // -pressureChangeWithEvent: sends as a mouse event with force: v0 x, v1 y (points,
                   // top left), v2 type: 0 pinch begin, 1 pinch update (v3 the scale step x 1e6,
                   // 1 + NSEvent magnification), 2 pinch end (also a cancelled pinch): PinchEvent's
                   // kGesturePinchBegin, Update and End; 3 smart magnify (a two-finger double tap):
                   // SmartMagnifyEvent; 4 pressure (v3 NSEvent pressure x 1e6, 0 to 1e6, v4 stage 0
                   // none, 1 click, 2 force click; Blink's WebPointerProperties::force); v5 pressed
                   // buttons as kMouse's, flags = NSEventModifierFlags, t0 event time. The host drops
                   // it until the fork can send it to the page
  // host -> cmux
  kReady = 101,         // v0 fork API version, v1 host pid, v2 what the host reports (kReadyReports*)
  kContext = 102,       // v0 CAContext id (bits of a uint32)
  kAddress = 103,       // payload url (main frame)
  kTitle = 104,         // payload title
  kPong = 105,          // t0 echoed, t1 host receive time
  kStatsReply = 106,    // seq of the request; v0 input events, v1 p50, v2 p95, v3 p99, v4 max (us from cmux's
                        // event time to the host's Send*Event on its UI thread, over the last kHopWindow
                        // events), v5 frames refused (unknown kind), t1 input frames coalesced into a
                        // waiting one (FrameQueue), t0 high 32 bits: times the host became active, low
                        // 32 bits: times one of its windows became key (each undone at once)
  kError = 107,         // payload message
  kRendererGone = 108,  // v0 cef_termination_status_t
  kTextInputState = 109,  // the focused field's text input state while watched (host_text_input.h's
                          // TextInputState): v0 ui::TextInputType, v1 flags, v2 v3
                          // selection (-1 -1 unknown), v4 v5 composition (-1 -1 none); payload i32 caret
                          // x, y, width, height, i32 text offset, i32 rect count, per composition
                          // character i32 x, y, width, height (page-view points, top left), then the
                          // text around the selection as UTF-16LE
  kInputPresented = 110,  // t0 the input frame's t0 (its event time), t1 when the frame that shows it reached the
                          // display, v0 gfx::PresentationFeedback flags (InputPresentedFrame)
};

struct Header {
  uint32_t kind = 0;
  uint32_t payload = 0;
  int32_t v[6] = {0, 0, 0, 0, 0, 0};
  uint64_t flags = 0;
  uint64_t t0 = 0;
  uint64_t t1 = 0;
  uint16_t ch = 0;
  uint16_t unmod = 0;
  uint32_t seq = 0;
};

// A wheel frame (kWheel). Chrome builds its wheel event
// from the NSEvent with the trackpad's scroll phase, its momentum phase and
// whether the deltas are precise (WebMouseWheelEventBuilder::Build in
// content/browser/renderer_host/input/web_input_event_builders_mac.mm), and its
// renderer host latches a gesture and hands the fling to the page from them
// (components/input/mouse_wheel_phase_handler.cc), so the frame carries them:
// v2 v3 NSEvent scrollingDeltaX/Y times kWheelDeltaScale, rounded (pixels when
// precise, lines when not; WheelOf gives pixels); v4 NSEvent.phase and v5
// NSEvent.momentumPhase as NSEventPhase bits; kWheelPrecise in flags for
// hasPreciseScrollingDeltas.
inline constexpr int32_t kWheelDeltaScale = 100;
inline constexpr uint64_t kWheelPrecise = uint64_t{1} << 63;
// NSEventPhase.
inline constexpr int32_t kNSPhaseBegan = 1 << 0;
inline constexpr int32_t kNSPhaseStationary = 1 << 1;
inline constexpr int32_t kNSPhaseChanged = 1 << 2;
inline constexpr int32_t kNSPhaseEnded = 1 << 3;
inline constexpr int32_t kNSPhaseCancelled = 1 << 4;
inline constexpr int32_t kNSPhaseMayBegin = 1 << 5;
// NSEventModifierFlags.
inline constexpr uint64_t kNSFlagCapsLock = uint64_t{1} << 16;
inline constexpr uint64_t kNSFlagShift = uint64_t{1} << 17;
inline constexpr uint64_t kNSFlagControl = uint64_t{1} << 18;
inline constexpr uint64_t kNSFlagOption = uint64_t{1} << 19;
inline constexpr uint64_t kNSFlagCommand = uint64_t{1} << 20;
// cef_event_flags_t (include/internal/cef_types.h; browser_host_main.mm checks
// them against CEF's).
inline constexpr int kCefCapsLockOn = 1 << 0;
inline constexpr int kCefShiftDown = 1 << 1;
inline constexpr int kCefControlDown = 1 << 2;
inline constexpr int kCefAltDown = 1 << 3;
inline constexpr int kCefCommandDown = 1 << 7;
inline constexpr int kCefPrecisionScrollingDelta = 1 << 14;
// A line of a wheel with no precise deltas, in pixels: Chrome's
// kScrollbarPixelsPerCocoaTick, which WebMouseWheelEventBuilder multiplies
// [NSEvent deltaX/Y] by.
inline constexpr int32_t kPixelsPerCocoaTick = 40;

// The phases of cmux_shim_browser_send_wheel (the fork's wheel call).
enum WheelPhase : int {
  kWheelPhaseNone = 0,
  kWheelPhaseMayBegin = 1,
  kWheelPhaseBegan = 2,
  kWheelPhaseChanged = 3,
  kWheelPhaseEnded = 4,
  kWheelPhaseCancelled = 5,
};

// A wheel frame's fields as the fork's wheel call takes them (pixel deltas,
// cmux_shim_browser_send_wheel in cmux_cef_shim.h).
struct Wheel {
  double x = 0;   // page view points, top left
  double y = 0;
  double dx = 0;  // pixels: scrollingDeltaX/Y when precise, lines x kPixelsPerCocoaTick when not
  double dy = 0;
  bool precise = false;
  int phase = kWheelPhaseNone;
  int momentum_phase = kWheelPhaseNone;
  int modifiers = 0;  // cef_event_flags_t
};

// The frame that showed an input reached the display (kInputPresented).
// Chrome closes each input's EventMetrics at the presentation
// feedback of the compositor frame that carried it
// (cc/metrics/compositor_frame_reporter.cc, gfx::PresentationFeedback in
// ui/gfx/presentation_feedback.h); the host reports that feedback per input
// by the input frame's t0, the one id cmux's latency slot and the frame share
// (InputLatencyTracker.hostPresented). Fork item for PL-cef-layer: the fork
// calls the host back with (event time, presentation timestamp, flags) for
// each input event of a presented frame. A host on such a fork sets
// kReadyReportsInputPresented in its kReady's v2; without it the host sends
// nothing and cmux closes each page slot at its turn's commit, with that
// commit's vsync estimate.
inline constexpr int32_t kReadyReportsInputPresented = 1 << 0;
// gfx::PresentationFeedback::Flags.
inline constexpr uint32_t kPresentationVSync = 1u << 0;
inline constexpr uint32_t kPresentationFailed = 1u << 1;
inline constexpr uint32_t kPresentationHWClock = 1u << 2;
inline constexpr uint32_t kPresentationHWCompletion = 1u << 3;

namespace detail {
template <typename T>
inline void Put(uint8_t* out, size_t offset, T value) {
  for (size_t i = 0; i < sizeof(T); ++i) out[offset + i] = static_cast<uint8_t>(static_cast<uint64_t>(value) >> (8 * i));
}
template <typename T>
inline T Get(const uint8_t* in, size_t offset) {
  uint64_t value = 0;
  for (size_t i = 0; i < sizeof(T); ++i) value |= static_cast<uint64_t>(in[offset + i]) << (8 * i);
  return static_cast<T>(value);
}
}  // namespace detail

inline void Encode(const Header& h, uint8_t out[kHeaderSize]) {
  using detail::Put;
  Put<uint32_t>(out, 0, h.kind);
  Put<uint32_t>(out, 4, h.payload);
  for (int i = 0; i < 6; ++i) Put<uint32_t>(out, 8 + 4 * i, static_cast<uint32_t>(h.v[i]));
  Put<uint64_t>(out, 32, h.flags);
  Put<uint64_t>(out, 40, h.t0);
  Put<uint64_t>(out, 48, h.t1);
  Put<uint16_t>(out, 56, h.ch);
  Put<uint16_t>(out, 58, h.unmod);
  Put<uint32_t>(out, 60, h.seq);
}

// False when the header announces a payload longer than kMaxPayload.
inline bool Decode(const uint8_t in[kHeaderSize], Header* h) {
  using detail::Get;
  h->kind = Get<uint32_t>(in, 0);
  h->payload = Get<uint32_t>(in, 4);
  for (int i = 0; i < 6; ++i) h->v[i] = static_cast<int32_t>(Get<uint32_t>(in, 8 + 4 * i));
  h->flags = Get<uint64_t>(in, 32);
  h->t0 = Get<uint64_t>(in, 40);
  h->t1 = Get<uint64_t>(in, 48);
  h->ch = Get<uint16_t>(in, 56);
  h->unmod = Get<uint16_t>(in, 58);
  h->seq = Get<uint32_t>(in, 60);
  return h->payload <= kMaxPayload;
}

// A kInputPresented frame: the input of event time `event_time_ns` (its
// frame's t0) showed in a frame presented at `presented_ns` (CLOCK_UPTIME_RAW
// nanoseconds) with gfx::PresentationFeedback `flags`.
inline Header InputPresentedFrame(uint64_t event_time_ns, uint64_t presented_ns, uint32_t flags) {
  Header h;
  h.kind = kInputPresented;
  h.v[0] = static_cast<int32_t>(flags);
  h.t0 = event_time_ns;
  h.t1 = presented_ns;
  return h;
}

// One NSEventPhase as the fork's phase. A stationary gesture (fingers down,
// not moving) is a change with no delta, as Blink's kPhaseStationary only
// keeps the gesture latched.
inline int WheelPhaseOf(int32_t ns_phase) {
  if (ns_phase & kNSPhaseCancelled) return kWheelPhaseCancelled;
  if (ns_phase & kNSPhaseEnded) return kWheelPhaseEnded;
  if (ns_phase & kNSPhaseBegan) return kWheelPhaseBegan;
  if (ns_phase & (kNSPhaseChanged | kNSPhaseStationary)) return kWheelPhaseChanged;
  if (ns_phase & kNSPhaseMayBegin) return kWheelPhaseMayBegin;
  return kWheelPhaseNone;
}

// NSEventModifierFlags as cef_event_flags_t.
inline int CefModifiersOf(uint64_t ns_flags) {
  int flags = 0;
  if (ns_flags & kNSFlagCapsLock) flags |= kCefCapsLockOn;
  if (ns_flags & kNSFlagShift) flags |= kCefShiftDown;
  if (ns_flags & kNSFlagControl) flags |= kCefControlDown;
  if (ns_flags & kNSFlagOption) flags |= kCefAltDown;
  if (ns_flags & kNSFlagCommand) flags |= kCefCommandDown;
  return flags;
}

// A kWheel frame's fields.
inline Wheel WheelOf(const Header& h) {
  Wheel wheel;
  wheel.x = h.v[0];
  wheel.y = h.v[1];
  wheel.precise = (h.flags & kWheelPrecise) != 0;
  const double scale = wheel.precise ? 1 : kPixelsPerCocoaTick;
  wheel.dx = h.v[2] * scale / kWheelDeltaScale;
  wheel.dy = h.v[3] * scale / kWheelDeltaScale;
  wheel.phase = WheelPhaseOf(h.v[4]);
  wheel.momentum_phase = WheelPhaseOf(h.v[5]);
  wheel.modifiers = CefModifiersOf(h.flags);
  return wheel;
}

// SendMouseWheelEvent's whole pixel deltas.
struct WheelPixels {
  int dx = 0;
  int dy = 0;
};

// The deltas for CefBrowserHost::SendMouseWheelEvent, on a fork with no wheel
// call, which takes whole pixels (as WheelOf: a line is kPixelsPerCocoaTick).
// Each frame's fraction carries to the next frame of the same browser and
// gesture, as the OS carries it in the CG integer point deltas, so a slow
// trackpad scroll of under half a pixel a frame still moves the page. A
// gesture's or momentum's start or end, a change of browser or of precise
// clears the carry. UI thread.
class WheelPixelCarry {
 public:
  WheelPixels Take(int32_t browser, const Header& frame) {
    const bool precise = (frame.flags & kWheelPrecise) != 0;
    const int phase = WheelPhaseOf(frame.v[4]);
    const int momentum_phase = WheelPhaseOf(frame.v[5]);
    if (browser != browser_ || precise != precise_ || IsStart(phase) || IsStart(momentum_phase)) Clear();
    browser_ = browser;
    precise_ = precise;
    const int64_t scale = precise ? 1 : kPixelsPerCocoaTick;
    const WheelPixels pixels{Whole(&dx_, frame.v[2] * scale), Whole(&dy_, frame.v[3] * scale)};
    if (IsEnd(phase) || IsEnd(momentum_phase)) Clear();
    return pixels;
  }

 private:
  static bool IsStart(int phase) { return phase == kWheelPhaseMayBegin || phase == kWheelPhaseBegan; }
  static bool IsEnd(int phase) { return phase == kWheelPhaseEnded || phase == kWheelPhaseCancelled; }
  // Adds hundredths of a pixel to `carry` and takes its whole pixels out.
  static int Whole(int64_t* carry, int64_t hundredths) {
    *carry += hundredths;
    const int64_t whole = std::clamp<int64_t>(*carry / kWheelDeltaScale, INT32_MIN, INT32_MAX);
    *carry -= whole * kWheelDeltaScale;
    return static_cast<int>(whole);
  }
  void Clear() { dx_ = dy_ = 0; }

  int32_t browser_ = 0;
  bool precise_ = false;
  int64_t dx_ = 0;  // hundredths of a pixel not sent yet
  int64_t dy_ = 0;
};

// The time Chromium gives an input frame's event: its t0,
// the NSEvent's timestamp, as Chrome stamps each event with
// ui::EventTimeStampFromSeconds([event timestamp])
// (content/browser/renderer_host/input/web_input_event_builders_mac.mm), so
// EventLatency and the page's event.timeStamp start at the OS event, not at the
// host's dispatch. 0 (the time it is sent) for a frame that is not input or has
// no event time, and for a t0 later than `now_ns`, which is not of this clock
// (ui::ValidateEventTimeClock in ui/events/base_event_utils.cc replaces such a
// time with now).
inline uint64_t EventTimeOf(const Header& frame, uint64_t now_ns) {
  if (frame.kind != kMouse && frame.kind != kWheel && frame.kind != kKey) return 0;
  return frame.t0 <= now_ns ? frame.t0 : 0;
}

// One ordered input stream. Chrome sends input and the
// view's state (focus, IME, edit commands, geometry) to the renderer host on
// one ordered pipe, RenderWidgetHostNSViewHost
// (content/common/render_widget_host_ns_view.mojom), so a key after a focus
// change goes to the newly focused page and a click after a resize hits the
// resized page. The host has two streams instead, the input ring (task 041)
// and the control channel (chromium_host_control.h), and joins them back
// into one order with a sequence number each way:
//   - an input frame's (IsOrderedInput) `seq` is cmux's input sequence number
//     (1, 2, ...; kPing and kStats keep `seq` as their request id and are not
//     ordered: they keep only their place in the ring), and
//     the high 32 bits of `t1` the control seq of the last control message
//     cmux accepted before it (CtlSeqOf; the low 32 bits name the page, task
//     041); the host dispatches it only once that control message is applied;
//   - a control message carries its own control seq and the input seq of the
//     last input frame cmux wrote before it (control::Message::ctl_seq and
//     after_input); the host applies it only once that frame is dispatched.
// control::OrderedStream holds each until the other side catches up. Seq 0 is
// "none"; both counters skip it when they wrap (NextSeq).
inline uint32_t CtlSeqOf(const Header& h) {
  return static_cast<uint32_t>(h.t1 >> 32);
}
inline void SetCtlSeq(Header* h, uint32_t ctl_seq) {
  h->t1 = (h->t1 & uint64_t{0xffffffff}) | (static_cast<uint64_t>(ctl_seq) << 32);
}

// The kinds whose `seq` is an input seq on the ordered stream: input and the
// view state the ring carries with it. kNavigate, kPing, kStats and kQuit are
// not: OrderedStream hands them on in ring order with no seq check.
inline bool IsOrderedInput(const Header& h) {
  switch (h.kind) {
    case kGeometry:
    case kMouse:
    case kWheel:
    case kKey:
    case kFocus:
    case kEdit:
    case kGesture:
      return true;
    default:
      return false;
  }
}

// A kMouse down or up's button as CEF clicks it (cef_mouse_button_type_t MBT_LEFT 0, MBT_MIDDLE 1,
// MBT_RIGHT 2: the wire's values), or kNoClickButton for any other v3. CEF's SendMouseClickEvent has
// no back or forward button, and a frame that names one must never become a left click at the
// pointer: the host's SendMouse dispatches no click for it.
inline constexpr int32_t kNoClickButton = -1;
inline int32_t ClickButtonOf(const Header& h) {
  return h.v[3] >= 0 && h.v[3] <= 2 ? h.v[3] : kNoClickButton;
}

// The seq after `seq`, skipping 0.
inline uint32_t NextSeq(uint32_t seq) {
  return seq == UINT32_MAX ? 1 : seq + 1;
}

// Whether `a` is `b` or comes before it, in serial number arithmetic (RFC 1982)
// so the order holds across a wrap: the two are never 2^31 apart, as no side
// holds that many frames.
inline bool SeqAtOrBefore(uint32_t a, uint32_t b) {
  return static_cast<int32_t>(a - b) <= 0;
}

// A frame the reader thread hands to the UI thread.
struct QueuedFrame {
  Header header;
  std::string payload;
};

// True for a pointer move (kMouse phase 0): a newer one replaces it.
inline bool IsPointerMove(const Header& h) {
  return h.kind == kMouse && h.v[2] == 0;
}

// The frames the reader thread has read and the UI thread has not run yet.
// Bounded: a newer pointer move replaces a waiting move, wheel deltas add up
// into the waiting wheel frame of the same phases and a newer geometry replaces a waiting one,
// each only at the tail, so the order of moves, clicks, keys and geometry
// stays the order cmux sent. Keys, clicks and every other frame are never
// dropped. More than `limit` waiting frames (a UI thread that has stopped)
// is a flood: Push refuses, and the reader ends the host as at EOF.
//
// One wake per batch: Push asks the caller to post one drain task when none is
// pending, and Take (the drain, on the UI thread) takes every waiting frame.
// Until MarkReady (Chromium's UI thread exists) frames only wait. Any thread;
// one mutex, held for a few pointer writes.
class FrameQueue {
 public:
  enum class Push { kWake, kWaiting, kFull };

  explicit FrameQueue(size_t limit) : limit_(limit) {}

  // The reader thread. kWake: post one drain task. kWaiting: a drain is
  // pending (or the UI thread is not ready); nothing to post. kFull: the
  // frame was not queued.
  Push Add(const Header& h, std::string payload) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!frames_.empty() && Coalesce(&frames_.back().header, h)) {
      ++coalesced_;
      return WakeLocked();
    }
    if (frames_.size() >= limit_) return Push::kFull;
    frames_.push_back(QueuedFrame{h, std::move(payload)});
    return WakeLocked();
  }

  // The reader thread at EOF or a broken wire: a kQuit after every waiting
  // frame, also when the queue is full. Same answer as Add.
  Push AddEnd() {
    std::lock_guard<std::mutex> lock(mutex_);
    Header quit;
    quit.kind = kQuit;
    frames_.push_back(QueuedFrame{quit, std::string()});
    return WakeLocked();
  }

  // The UI thread, once: true when frames wait (post one drain task).
  bool MarkReady() {
    std::lock_guard<std::mutex> lock(mutex_);
    ready_ = true;
    return WakeLocked() == Push::kWake;
  }

  // The drain task: every waiting frame, oldest first; the next Add wakes again.
  std::deque<QueuedFrame> Take() {
    std::lock_guard<std::mutex> lock(mutex_);
    wake_pending_ = false;
    std::deque<QueuedFrame> taken;
    taken.swap(frames_);
    return taken;
  }

  size_t size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frames_.size();
  }
  // Frames folded into a waiting one since start (kStatsReply t1).
  uint64_t coalesced() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return coalesced_;
  }

 private:
  // Folds `next` into `waiting` when it only updates it: never across an
  // ordered control message (another CtlSeqOf), which `waiting` must still
  // meet before it, nor across pages (t1's low bits, task 041).
  static bool Coalesce(Header* waiting, const Header& next) {
    if (next.payload != 0 || waiting->payload != 0) return false;
    if (waiting->t1 != next.t1) return false;
    if (IsPointerMove(*waiting) && IsPointerMove(next) && waiting->flags == next.flags &&
        waiting->v[5] == next.v[5]) {
      *waiting = next;  // the newest position, buttons and event time
      return true;
    }
    // Wheels fold only within one phase and momentum phase, as Blink's
    // WebMouseWheelEvent::CanCoalesce (third_party/blink/common/input/
    // web_mouse_wheel_event.cc): a gesture's begin and end, and the switch to
    // momentum, each reach Chromium.
    if (waiting->kind == kWheel && next.kind == kWheel && waiting->flags == next.flags &&
        waiting->v[4] == next.v[4] && waiting->v[5] == next.v[5]) {
      const int32_t dx = waiting->v[2], dy = waiting->v[3];
      *waiting = next;  // the newest position and event time, the summed deltas
      waiting->v[2] = SaturatingAdd(dx, next.v[2]);
      waiting->v[3] = SaturatingAdd(dy, next.v[3]);
      return true;
    }
    if (waiting->kind == kGeometry && next.kind == kGeometry) {
      *waiting = next;
      return true;
    }
    return false;
  }

  static int32_t SaturatingAdd(int32_t a, int32_t b) {
    const int64_t sum = static_cast<int64_t>(a) + b;
    return static_cast<int32_t>(std::clamp<int64_t>(sum, INT32_MIN, INT32_MAX));
  }

  Push WakeLocked() {
    if (!ready_ || wake_pending_ || frames_.empty()) return Push::kWaiting;
    wake_pending_ = true;
    return Push::kWake;
  }

  const size_t limit_;
  mutable std::mutex mutex_;
  std::deque<QueuedFrame> frames_;
  bool ready_ = false;
  bool wake_pending_ = false;
  uint64_t coalesced_ = 0;
};

}  // namespace cmux_host
