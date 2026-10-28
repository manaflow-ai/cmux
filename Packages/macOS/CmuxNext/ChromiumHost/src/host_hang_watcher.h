// Hang detection of the Chromium Host's UI thread
// (plans/cmux-next/chrome-parity/p01-process.md design items 7 and 8). Needs no
// CEF: tests/host_hang_watcher_test.cpp (scripts/cmux-next/tests/
// chromium-host-wire.test.sh) compiles it alone; host_hang_watcher.mm puts it
// on the host's main run loop.
//
// Scopes. Chrome's HangWatcher (base/threading/hang_watcher.h) gives each
// unit of UI work a deadline with WatchHangsInScope and records a hang with
// base::debug::DumpWithoutCrashing once a scope outlives
// kDefaultHangWatchTime (10 s). Here a scope is one turn of the host's main
// run loop (the work between waking up and going back to sleep, or between
// two passes over its sources): BeginTurn and EndTurn, called by a run loop
// observer. EndTurn measures the turn on the UI thread itself and sends one
// kOpHostHang when it took kReportNs (250 ms) or more, so cmux's hang reports
// get every host UI hang the person could feel, tagged host.
//
// The watcher. Chrome's watcher polls every kHangWatcherMonitoringPeriod
// (10 s), also while the browser is idle. This one parks with no deadline
// while no scope is open (and after it dumped the open one), so an idle host
// has no watcher wakeups at all: the next BeginTurn wakes it, and it looks
// again kDumpNs later, so a busy host wakes it at most once per kDumpNs, as
// Chrome's watcher wakes once per period. While a scope is open it sleeps
// until that scope is kDumpNs old and,
// if the same scope is still open then, writes a dump without crashing and
// sends kOpHostHang with kHangOngoing (a host the person then reloads leaves
// its report). It waits in poll on a non-blocking pipe, with no timeout while
// parked, as the control channel's reader waits on its wake byte
// (chromium_host_control.cc): no lock, and the UI thread's wake is one write
// that never blocks. A turn's hang is claimed once, by the watcher's dump or
// by the turn's end, whichever comes first (a monotonic compare-exchange on
// `claimed_`): the end's report says kHangReported when the watcher's ongoing
// report claimed it, so cmux takes each hang once whether or not the watcher
// ran. The park is Dekker's: the watcher publishes `parked_` and
// then reads the turn again; BeginTurn publishes the turn and then reads
// `parked_` (all sequentially consistent), so one of them sees the other.
//
// Input acks. The host acks input at dispatch on its UI thread, not at the
// renderer (p01-process.md 3.1, "Ack"): FrameDispatched records the input seq
// of each ordered input frame the dispatch gave Chromium (IsOrderedInput: a
// kPing's or kStats' `seq` is its request id, never acked), and the turn's end
// sends the newest one as one kOpInputDispatched, so a turn that dispatched a
// batch acks it once. Input on the control channel (wheels, locked mouse
// moves and widget input until the ring carries them) is acked per op by the
// kOpAck its dispatch already sends. cmux's ChromiumHostHangMonitor arms one
// deadline only while input is not acked and shows "Chromium is busy" when
// none came for 2 s (InputAcks below is its count, kept by the remote shim).
//
// Wire (host -> cmux; remote_shim.mm takes both, the HELLO lists
// kHangWatchHelloName when the host sends them):
//   kOpHostHang        i64 duration (ns), i32 flags (kHangOngoing, kHangDumped, kHangReported)
//   kOpInputDispatched i32 the newest input seq dispatched (its bit pattern)
#pragma once

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <functional>
#include <thread>
#include <utility>

#include "chromium_host_control.h"
#include "chromium_host_tlv.h"
#include "chromium_host_wire.h"

namespace cmux_host::hang {

// Host -> cmux, next to kOpEnergySaver (host_energy_saver.h): not in the generated op table.
inline constexpr uint16_t kOpHostHang = 0x8010;
inline constexpr uint16_t kOpInputDispatched = 0x8011;
// In the HELLO when the host sends both.
inline constexpr char kHangWatchHelloName[] = "cmux_host_hang_watch";
// The watcher thread's label (plans/cmux-next/threading-model.md).
inline constexpr const char* kWatcherLabel = "com.cmuxterm.chromium-host.hang-watcher";

// kOpHostHang flags.
inline constexpr int32_t kHangOngoing = 1;  // the turn still runs (the watcher's report at the dump)
inline constexpr int32_t kHangDumped = 2;   // a dump of the hang was written
inline constexpr int32_t kHangReported = 4;  // the turn's end: the watcher's ongoing report already sent this hang
inline constexpr int32_t kHangFlags = kHangOngoing | kHangDumped | kHangReported;

struct Limits {
  // A turn this long is a hang report: cmux's own jank threshold (MainThreadWatchdog's 250 ms lag spike).
  uint64_t report_ns = 250'000'000;
  // A turn this long gets a dump: kDefaultHangWatchTime (base/threading/hang_watcher.cc).
  uint64_t dump_ns = 10'000'000'000;
};

struct Hang {
  uint64_t duration_ns = 0;
  int32_t flags = 0;
  bool operator==(const Hang& other) const { return duration_ns == other.duration_ns && flags == other.flags; }
};

inline control::Message HangMessage(const Hang& hang) {
  control::TlvWriter w;
  w.I64(static_cast<int64_t>(hang.duration_ns));
  w.I32(hang.flags);
  control::Message message;
  message.op = kOpHostHang;
  message.fields = w.Take();
  return message;
}

// False for a malformed kOpHostHang (cmux ends the host).
inline bool ReadHang(const control::Message& message, Hang* out) {
  control::TlvReader r(message.fields);
  const int64_t duration = r.I64();
  const int32_t flags = r.I32();
  if (!r.ok() || !r.AtEnd() || duration < 0 || (flags & ~kHangFlags) != 0) return false;
  *out = Hang{static_cast<uint64_t>(duration), flags};
  return true;
}

inline control::Message DispatchedMessage(uint32_t seq) {
  control::TlvWriter w;
  w.U32(seq);
  control::Message message;
  message.op = kOpInputDispatched;
  message.fields = w.Take();
  return message;
}

// False for a malformed kOpInputDispatched (seq 0 is never an input seq).
inline bool ReadDispatched(const control::Message& message, uint32_t* seq) {
  control::TlvReader r(message.fields);
  const uint32_t value = r.U32();
  if (!r.ok() || !r.AtEnd() || value == 0) return false;
  *seq = value;
  return true;
}

// What the watcher does next (Watch::Check).
struct Next {
  enum class Kind { kPark, kSleep, kDump };
  Kind kind = Kind::kPark;
  uint64_t until_ns = 0;  // kSleep: when to look again
  uint64_t turn = 0;      // kDump: the turn to dump
};

// The UI thread's turns and the watcher thread over them.
class Watch {
 public:
  // CLOCK_UPTIME_RAW nanoseconds in the host (base::TimeTicks on macOS); never 0.
  using Now = uint64_t (*)();
  // Sends a message to cmux; any thread, never blocks (control::Channel::Send).
  using Send = std::function<bool(const control::Message&)>;
  // Writes a dump without crashing; the watcher thread. True when one was written.
  using Dump = std::function<bool()>;
  // Runs first on the watcher thread (its label and QoS in the host).
  using ThreadStart = void (*)();

  Watch(Now now, Send send, Dump dump, Limits limits = Limits(), ThreadStart thread_start = nullptr)
      : now_(now), send_(std::move(send)), dump_(std::move(dump)), limits_(limits), thread_start_(thread_start) {}
  Watch(const Watch&) = delete;
  Watch& operator=(const Watch&) = delete;
  ~Watch() { Stop(); }

  // UI thread: a turn begins (the one open ends first).
  void BeginTurn() {
    const uint64_t now = now_();
    if (open_) Close(now);
    turn_ = turn_id_.load(std::memory_order_relaxed) + 1;
    turn_id_.store(turn_, std::memory_order_seq_cst);
    turn_begin_.store(now == 0 ? 1 : now, std::memory_order_seq_cst);
    open_ = true;
    if (parked_.load(std::memory_order_seq_cst) && parked_.exchange(false, std::memory_order_seq_cst)) Wake();
  }

  // UI thread: the open turn ends (the run loop waits, or leaves).
  void EndTurn() {
    if (open_) Close(now_());
  }

  // UI thread: the input dispatch handed `frame` to Chromium. Only ordered
  // input carries an input seq (a kPing's or kStats' seq is its request id).
  void FrameDispatched(const Header& frame) {
    if (IsOrderedInput(frame)) InputDispatched(frame.seq);
  }

  // UI thread: the input dispatch gave Chromium the frame of input seq `seq`.
  // The turn's end acks the newest one; outside a turn it is acked now.
  void InputDispatched(uint32_t seq) {
    if (seq == 0) return;
    if (dispatched_ == 0 || SeqAtOrBefore(dispatched_, seq)) dispatched_ = seq;
    if (!open_) FlushDispatched();
  }

  // False when the wake pipe cannot be made: the host then runs unwatched.
  bool Start() {
    if (thread_.joinable()) return true;
    if (!OpenPipe()) return false;
    thread_ = std::thread([this] { Run(); });
    return true;
  }

  // Any thread but the watcher's; waits for a dump in progress.
  void Stop() {
    if (thread_.joinable()) {
      stop_.store(true, std::memory_order_seq_cst);
      Wake();
      thread_.join();
    }
    for (int& fd : pipe_) {
      if (fd >= 0) ::close(fd);
      fd = -1;
    }
  }

  // What the watcher does at `now`: park while no turn is open or the open
  // one was dumped, dump the open turn once it is dump_ns old, else sleep
  // until then. Any thread.
  Next Check(uint64_t now) const {
    uint64_t turn = turn_id_.load(std::memory_order_seq_cst);
    uint64_t begin = turn_begin_.load(std::memory_order_seq_cst);
    // A turn id and begin of the same turn (BeginTurn stores the id, then the begin).
    while (turn != turn_id_.load(std::memory_order_seq_cst)) {
      turn = turn_id_.load(std::memory_order_seq_cst);
      begin = turn_begin_.load(std::memory_order_seq_cst);
    }
    if (begin == 0 || claimed_.load(std::memory_order_seq_cst) >= turn) return Next{Next::Kind::kPark, 0, turn};
    const uint64_t due = begin + limits_.dump_ns;
    if (now >= due) return Next{Next::Kind::kDump, 0, turn};
    return Next{Next::Kind::kSleep, due, turn};
  }

  // The watcher thread: dumps `turn` when it is still open, and reports it
  // as ongoing. Public for the tests, which drive Check and DumpTurn
  // without the thread.
  void DumpTurn(uint64_t turn, uint64_t now) {
    const uint64_t begin = turn_begin_.load(std::memory_order_seq_cst);
    if (turn_id_.load(std::memory_order_seq_cst) != turn || begin == 0) return;
    if (!Claim(turn)) return;  // dumped already, or its end reported it
    const bool written = dump_ && dump_();
    if (written) dump_written_.store(turn, std::memory_order_release);
    ++dumps_;
    send_(HangMessage(Hang{now > begin ? now - begin : 0, kHangOngoing | (written ? kHangDumped : 0)}));
  }

  // Times the watcher woke from a park or a sleep, and dumps it tried (the tests).
  uint64_t wakes() const { return wakes_.load(std::memory_order_relaxed); }
  uint64_t dumps() const { return dumps_.load(std::memory_order_relaxed); }
  // The watcher waits with no deadline (the tests).
  bool parked() const { return parked_.load(std::memory_order_seq_cst); }

 private:
  // UI thread.
  void Close(uint64_t now) {
    const uint64_t begin = turn_begin_.load(std::memory_order_relaxed);
    turn_begin_.store(0, std::memory_order_seq_cst);
    open_ = false;
    // False: the watcher claimed this turn first, and its ongoing report has gone or goes.
    const bool first = Claim(turn_);
    const uint64_t duration = now > begin ? now - begin : 0;
    if (duration >= limits_.report_ns) {
      const bool dumped = dump_written_.load(std::memory_order_acquire) == turn_;
      send_(HangMessage(Hang{duration, (dumped ? kHangDumped : 0) | (first ? 0 : kHangReported)}));
    }
    FlushDispatched();
  }

  // Either thread: true for the first claim of `turn` (claims only move forward).
  bool Claim(uint64_t turn) {
    uint64_t claimed = claimed_.load(std::memory_order_seq_cst);
    do {
      if (claimed >= turn) return false;
    } while (!claimed_.compare_exchange_weak(claimed, turn, std::memory_order_seq_cst));
    return true;
  }

  void FlushDispatched() {
    if (dispatched_ == 0) return;
    send_(DispatchedMessage(dispatched_));
    dispatched_ = 0;
  }

  bool OpenPipe() {
    if (::pipe(pipe_) != 0) return false;
    for (int fd : pipe_) {
      if (::fcntl(fd, F_SETFL, O_NONBLOCK) != 0 || ::fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
        for (int& end : pipe_) {
          ::close(end);
          end = -1;
        }
        return false;
      }
    }
    return true;
  }

  // Any thread: one byte, never waiting (a full pipe already wakes the watcher).
  void Wake() {
    const char byte = 1;
    if (pipe_[1] >= 0) (void)!::write(pipe_[1], &byte, 1);
  }

  int DumpPeriodMs() const {
    const uint64_t ms = (limits_.dump_ns + 999'999) / 1'000'000;
    return static_cast<int>(ms > 60'000 ? 60'000 : ms);
  }

  // The watcher thread: waits for a wake byte or `timeout_ms` (-1: none), then drops every byte.
  void WaitForWake(int timeout_ms) {
    pollfd wake = {pipe_[0], POLLIN, 0};
    // wakeup-allow: deadline an open turn's dump deadline only; a parked watcher passes -1 and waits for the wake byte
    while (::poll(&wake, 1, timeout_ms) < 0 && errno == EINTR) {
    }
    char bytes[64];
    while (::read(pipe_[0], bytes, sizeof bytes) > 0) {
    }
    ++wakes_;
  }

  // The watcher thread.
  void Run() {
    if (thread_start_) thread_start_();
    while (!stop_.load(std::memory_order_seq_cst)) {
      const Next next = Check(now_());
      switch (next.kind) {
        case Next::Kind::kPark:
          parked_.store(true, std::memory_order_seq_cst);
          if (Check(now_()).kind != Next::Kind::kPark || stop_.load(std::memory_order_seq_cst)) {
            parked_.store(false, std::memory_order_seq_cst);  // a turn began, or Stop came, meanwhile
            break;
          }
          WaitForWake(-1);  // no deadline: only BeginTurn or Stop ends it
          parked_.store(false, std::memory_order_seq_cst);
          // The turn that woke it may be over already: look again one dump period later, not at once, so
          // a host busy with short turns wakes the watcher once per period, not once per turn.
          if (!stop_.load(std::memory_order_seq_cst)) WaitForWake(DumpPeriodMs());
          break;
        case Next::Kind::kSleep: {
          const uint64_t now = now_();
          const uint64_t left_ms = next.until_ns > now ? (next.until_ns - now + 999'999) / 1'000'000 : 0;
          // wakeup-allow: deadline the open turn's dump deadline (kDumpNs), one per long turn, never while idle
          WaitForWake(static_cast<int>(left_ms > 60'000 ? 60'000 : left_ms));
          break;
        }
        case Next::Kind::kDump:
          DumpTurn(next.turn, now_());
          break;
      }
    }
  }

  const Now now_;
  const Send send_;
  const Dump dump_;
  const Limits limits_;
  const ThreadStart thread_start_;

  // Written by the UI thread, read by the watcher.
  std::atomic<uint64_t> turn_id_{0};
  std::atomic<uint64_t> turn_begin_{0};  // 0 while no turn is open
  // The newest turn whose hang was claimed: by the watcher's dump or by the turn's end (Claim).
  std::atomic<uint64_t> claimed_{0};
  // Written by the watcher, read by the UI thread.
  std::atomic<uint64_t> dump_written_{0};
  // Set by the watcher before it waits with no deadline; cleared by the BeginTurn that wakes it.
  std::atomic<bool> parked_{false};
  std::atomic<uint64_t> wakes_{0};
  std::atomic<uint64_t> dumps_{0};

  // The UI thread's own.
  bool open_ = false;
  uint64_t turn_ = 0;
  uint32_t dispatched_ = 0;  // 0: nothing to ack

  // The watcher waits on pipe_[0]; BeginTurn (from a park) and Stop write a byte to pipe_[1].
  int pipe_[2] = {-1, -1};
  std::atomic<bool> stop_{false};
  std::thread thread_;
};

// cmux's view of the host's input acks: the remote shim (main thread) counts
// the input it sends against the host's acks, and says when input starts
// waiting, when the host dispatched some of it with more still waiting, and
// when none waits. RenderWidgetHostImpl keeps the same count
// (in_flight_event_count_, content/browser/renderer_host/
// render_widget_host_impl.cc), with the renderer's ack where this has the
// host's dispatch. Two streams carry input to the host, each with its own ack:
//   ring     the input seqs cmux_remote_shim_order_input gives the input
//            ring's writer, acked by kOpInputDispatched (the newest seq a
//            UI turn dispatched)
//   control  the tokens of input ops on the control channel (PostInput's
//            wheels, locked mouse moves and widget input, the scripted
//            click), acked by the host's kOpAck of each once it ran
//            (HostContext::Ack after DispatchOp). The host applies the
//            channel in order, so its ack or answer of any token posted at or
//            after a waiting input op says that op ran.
// Seqs and tokens both count up and skip 0 (NextSeq, NextToken).
class InputAcks {
 public:
  enum class Change {
    kNone,
    kOutstanding,  // the first input that waits for the host
    kProgress,     // the host dispatched input; later input still waits
    kSettled,      // all input sent was dispatched (or went with the host)
  };

  // Ring input of seq `seq` was written.
  Change Written(uint32_t seq) { return Wrote(&ring_, seq); }
  // The host dispatched ring input up to `seq` (kOpInputDispatched).
  Change Dispatched(uint32_t seq) { return Acked(&ring_, seq); }
  // Control-channel input went out in the op of token `token`.
  Change ControlWritten(uint32_t token) { return Wrote(&control_, token); }
  // The host acked or answered the op of token `token`: the input ops posted
  // at or before it ran.
  Change ControlAcked(uint32_t token) { return Acked(&control_, token); }

  // The host ended or detached: nothing it took waits any longer.
  Change Reset() {
    const bool was = waiting();
    ring_ = Stream();
    control_ = Stream();
    return was ? Change::kSettled : Change::kNone;
  }

  bool waiting() const { return ring_.waiting || control_.waiting; }

 private:
  struct Stream {
    uint32_t oldest = 0;  // the oldest seq or token that may still wait
    uint32_t newest = 0;  // the newest one sent
    bool waiting = false;
  };

  Change Wrote(Stream* stream, uint32_t id) {
    if (id == 0) return Change::kNone;
    const bool was = waiting();
    if (!stream->waiting) stream->oldest = id;
    stream->newest = id;
    stream->waiting = true;
    return was ? Change::kNone : Change::kOutstanding;
  }

  // An ack before the oldest waiting id names input dispatched already.
  Change Acked(Stream* stream, uint32_t id) {
    if (!stream->waiting || id == 0 || !SeqAtOrBefore(stream->oldest, id)) return Change::kNone;
    if (SeqAtOrBefore(stream->newest, id)) {
      stream->waiting = false;
    } else {
      stream->oldest = NextSeq(id);
    }
    return waiting() ? Change::kProgress : Change::kSettled;
  }

  Stream ring_;
  Stream control_;
};

// The host's watch on its main run loop (host_hang_watcher.mm, Apple only):
// the turn observers, the uptime clock, the dump and the watcher thread
// started. Main thread; it outlives every turn and stops before the channel
// that `send` writes to closes.
class HostHangWatch {
 public:
  explicit HostHangWatch(Watch::Send send);
  HostHangWatch(const HostHangWatch&) = delete;
  HostHangWatch& operator=(const HostHangWatch&) = delete;
  ~HostHangWatch();

  // The input dispatch's ack of each frame it handed Chromium (Watch::FrameDispatched). UI thread.
  void FrameDispatched(const Header& frame) { watch_.FrameDispatched(frame); }
  // Ends the watcher and removes the observers (before the channel closes).
  void Stop();

 private:
  Watch watch_;
  void* begin_observer_ = nullptr;  // CFRunLoopObserverRef
  void* end_observer_ = nullptr;    // CFRunLoopObserverRef
};

}  // namespace cmux_host::hang
