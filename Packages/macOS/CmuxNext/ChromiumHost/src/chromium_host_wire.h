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
// The oldest fork API the host runs on: layer hosting (26) and the resize
// sync (27), so its Chromium never holds a commit for a resize on its own.
// cmux starts it with the switch set of this API (ChromiumHostConfiguration,
// CEFSwitches.resizeSyncForkAPI: no AsyncLiveResize).
inline constexpr int kMinForkAPI = 27;
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
                   // (0 left, 1 middle, 2 right), v4 click count, flags = NSEventModifierFlags, t0 event time
  kWheel = 4,      // v0 x, v1 y, v2 dx, v3 dy (pixels), flags, t0
  kKey = 5,        // v0 phase (0 down, 1 up, 2 flags changed), v1 key code, v2 repeat, flags, ch, unmod, t0;
                   // the host sends it with cmux_shim::SendHostKeyEvent and the frame's input seq, which
                   // KEY_UNHANDLED carries back for a chord the page leaves unhandled (p01-process-030)
  kFocus = 6,      // v0 1 focused, 0 not
  kPing = 7,       // t0 cmux send time; the host answers kPong
  kStats = 8,      // seq request id (never an input seq: not an IsOrderedInput kind); the host answers
                   // kStatsReply with the same seq
  kQuit = 9,
  kEdit = 10,      // v0 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo
  // host -> cmux
  kReady = 101,         // v0 fork API version, v1 host pid
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

// One ordered input stream (task p01-process-092). Chrome sends input and the
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
      return true;
    default:
      return false;
  }
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
// into the waiting wheel frame and a newer geometry replaces a waiting one,
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
    if (waiting->kind == kWheel && next.kind == kWheel && waiting->flags == next.flags) {
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
