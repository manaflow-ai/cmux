// The input ring from cmux to the Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md 3.1).
//
// Keys, clicks, pointer moves and wheel ticks go from cmux to the host in a
// single-producer, single-consumer ring of 4,096 frames of 64 bytes in a
// shared memory region, not on the control socket: one write is a few stores
// and a release store, with no system call unless the host's reader waits.
// Each frame is a chromium_host_wire.h Header (kKey, kMouse, kWheel fields as
// listed there) with no payload; `seq` is cmux's input sequence number and
// `t1` names the page: its low 32 bits are the client browser id
// (BrowserOf), and its high 32 bits stay 0 for the control seq the frame was
// written after (task 092). cmux's writer is
// ChromiumHostInputRing.swift; the C++ Writer below is the same algorithm,
// for the tests. Both sides check the same golden bytes
// (../tests/chromium_host_input_ring_test.cpp, ChromiumHostInputRingTests).
//
// Shared state lives in the mapping, as Chromium keeps its std::atomic words
// inside a mapped segment (base/metrics/persistent_memory_allocator.cc). Each
// word has its own 128-byte line (Apple silicon's cache line), so the writer's
// tail and the reader's head never share one.
//
// The doorbell. The reader drains, then parks: it sets `parked` and reads the
// tail again (both sequentially consistent); the writer stores the tail, then
// reads `parked` (both sequentially consistent) and, when it finds the reader
// parked, clears it and sends one Mach message. One side always sees the
// other's store (Dekker), so a frame never waits behind a parked reader. The
// doorbell is a Mach port, the transport of Mojo's ChannelMac
// (mojo/core/channel_mac.cc), with a queue limit of 1, and the writer sends
// with a zero timeout, so a ring never blocks (a doorbell already waiting is
// enough). The reader waits for it in a kqueue whose EVFILT_MACHPORT receives
// the message, as Chromium's MessagePumpKqueue waits on its wakeup port
// (base/message_loop/message_pump_kqueue.cc). A thread blocked in kevent64 on
// a plain kqueue gets no QoS override from the message (XNU applies one only
// to a workloop or a sync-IPC waiter), so the reader runs at user-interactive
// QoS itself (BecomeReaderThread) and needs none.
//
// cmux makes the region, passes it on the host's fd kRingFd at spawn and
// names the doorbell with --input-doorbell=<name>; the host checks the
// receive right in under that name (bootstrap_check_in, as Chromium's
// MachPortRendezvousServer does in base/apple/mach_port_rendezvous_mac.cc)
// before its HELLO, and cmux looks it up once after the HELLO, off main.
// HostInput below is the host's reader. browser_host_main.mm starts it when
// cmux passes --input-doorbell, dispatches each batch on Chromium's
// user-input queue and acks its moves and wheel ticks there (host_input.h,
// task 042).
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <thread>
#include <utility>
#include <vector>

#include "chromium_host_wire.h"

#if defined(__APPLE__)
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <sys/event.h>
#endif

namespace cmux_host::input_ring {

inline constexpr uint32_t kMagic = 0x52494d43;  // "CMIR"
inline constexpr uint32_t kVersion = 1;
inline constexpr uint64_t kCapacity = 4096;  // a power of two: a slot is `index & (kCapacity - 1)`
inline constexpr size_t kFrameSize = kHeaderSize;
inline constexpr size_t kMagicOffset = 0;
inline constexpr size_t kVersionOffset = 4;
inline constexpr size_t kCapacityOffset = 8;
inline constexpr size_t kFrameSizeOffset = 12;
inline constexpr size_t kTailOffset = 128;    // u64, frames written (the writer)
inline constexpr size_t kHeadOffset = 256;    // u64, frames read (the reader)
inline constexpr size_t kParkedOffset = 384;  // u64, 1 while the reader waits on the doorbell
inline constexpr size_t kFramesOffset = 512;
inline constexpr size_t kRingBytes = kFramesOffset + kCapacity * kFrameSize;
// The host's descriptor of the region.
inline constexpr int kRingFd = 5;
// The reader thread's label (plans/cmux-next/threading-model.md).
inline constexpr const char* kReaderLabel = "com.cmuxterm.chromium-host.input";

static_assert((kCapacity & (kCapacity - 1)) == 0, "the capacity is a power of two");
static_assert(std::atomic<uint64_t>::is_always_lock_free && sizeof(std::atomic<uint64_t>) == 8,
              "a ring word is a lock-free std::atomic over the mapped 8 bytes");

// The client browser id a ring frame is for.
inline int32_t BrowserOf(const Header& header) {
  return static_cast<int32_t>(static_cast<uint32_t>(header.t1));
}
inline void SetBrowser(Header* header, int32_t browser) {
  header->t1 = (header->t1 & ~uint64_t{0xffffffff}) | static_cast<uint32_t>(browser);
}

// A view of a mapped ring. Either side; it owns nothing.
class Ring {
 public:
  // Writes the ring's header into a zeroed mapping of kRingBytes (cmux, before the spawn).
  static void Format(void* mapping) {
    auto* bytes = static_cast<uint8_t*>(mapping);
    std::memset(bytes, 0, kFramesOffset);
    detail::Put<uint32_t>(bytes, kMagicOffset, kMagic);
    detail::Put<uint32_t>(bytes, kVersionOffset, kVersion);
    detail::Put<uint32_t>(bytes, kCapacityOffset, static_cast<uint32_t>(kCapacity));
    detail::Put<uint32_t>(bytes, kFrameSizeOffset, static_cast<uint32_t>(kFrameSize));
  }

  // True when `size` bytes at `mapping` hold a ring of this layout.
  static bool Valid(const void* mapping, size_t size) {
    const auto* bytes = static_cast<const uint8_t*>(mapping);
    return size >= kRingBytes && detail::Get<uint32_t>(bytes, kMagicOffset) == kMagic &&
           detail::Get<uint32_t>(bytes, kVersionOffset) == kVersion &&
           detail::Get<uint32_t>(bytes, kCapacityOffset) == kCapacity &&
           detail::Get<uint32_t>(bytes, kFrameSizeOffset) == kFrameSize;
  }

  explicit Ring(void* mapping) : base_(static_cast<uint8_t*>(mapping)) {}

  std::atomic<uint64_t>& Tail() const { return Word(kTailOffset); }
  std::atomic<uint64_t>& Head() const { return Word(kHeadOffset); }
  std::atomic<uint64_t>& Parked() const { return Word(kParkedOffset); }
  uint8_t* Slot(uint64_t index) const { return base_ + kFramesOffset + (index & (kCapacity - 1)) * kFrameSize; }

 private:
  // The mapped word as a std::atomic, as PersistentMemoryAllocator casts its
  // mapped header words (base/metrics/persistent_memory_allocator.cc).
  std::atomic<uint64_t>& Word(size_t offset) const {
    return *reinterpret_cast<std::atomic<uint64_t>*>(base_ + offset);
  }

  uint8_t* base_;
};

// The writer: cmux's is ChromiumHostInputRing.swift, step for step; this one
// is for the tests. One thread.
class Writer {
 public:
  enum class Push {
    kWritten,      // in the ring; the reader is awake or will read it before it waits
    kWrittenRing,  // in the ring, and the reader was parked: ring the doorbell
    kFull,         // not written: 4,096 frames wait (cmux spills it to its own backlog, never waits)
    kBroken,       // not written: the head is not a position the reader can be at
  };

  explicit Writer(void* mapping) : ring_(mapping), tail_(ring_.Tail().load(std::memory_order_relaxed)) {}

  Push Write(const Header& header) {
    if (tail_ - head_ >= kCapacity) {
      head_ = ring_.Head().load(std::memory_order_acquire);
      const uint64_t used = tail_ - head_;
      if (used > kCapacity) return Push::kBroken;
      if (used == kCapacity) return Push::kFull;
    }
    Encode(header, ring_.Slot(tail_));
    ++tail_;
    ring_.Tail().store(tail_, std::memory_order_seq_cst);
    if (ring_.Parked().load(std::memory_order_seq_cst) == 0) return Push::kWritten;
    return ring_.Parked().exchange(0, std::memory_order_seq_cst) != 0 ? Push::kWrittenRing : Push::kWritten;
  }

 private:
  Ring ring_;
  uint64_t tail_;
  uint64_t head_ = 0;  // the last head read: the writer reads the reader's line only when the ring looks full
};

// What a doorbell's Wait (on the reader thread) returned.
enum class Wake {
  kRung,     // a ring, or a wake that may be spurious: drain again
  kStopped,  // Stop was called
  kFailed,   // the doorbell can no longer wait (its kqueue or pipe failed)
};

// The reader: the host's input thread. One thread.
class Reader {
 public:
  enum class Drained {
    kEmpty,    // every written frame was handed out
    kRefused,  // the sink refused a frame; it stays first in the ring
    kBroken,   // the tail is not a position the writer can be at, or a frame has a payload
  };

  // Why Run returned.
  enum class End {
    kStopped,         // the doorbell was stopped
    kBroken,          // cmux wrote a position or a frame no writer can (a bad message)
    kDoorbellFailed,  // the doorbell failed: no ring would wake the reader again
  };

  explicit Reader(void* mapping) : ring_(mapping), head_(ring_.Head().load(std::memory_order_relaxed)) {}

  // Hands each frame written so far to `sink(const Header&)`, oldest first,
  // until it returns false, and frees the slots it took. Frames written
  // during the drain wait for the next one (Park sees them).
  template <typename Sink>
  Drained Drain(Sink&& sink) {
    const uint64_t tail = ring_.Tail().load(std::memory_order_acquire);
    if (tail - head_ > kCapacity) return Drained::kBroken;
    const uint64_t start = head_;
    Drained result = Drained::kEmpty;
    while (head_ != tail) {
      Header header;
      if (!Decode(ring_.Slot(head_), &header) || header.payload != 0) {
        result = Drained::kBroken;
        break;
      }
      if (!sink(static_cast<const Header&>(header))) {
        result = Drained::kRefused;
        break;
      }
      ++head_;
    }
    if (head_ != start) ring_.Head().store(head_, std::memory_order_release);
    return result;
  }

  // Before waiting on the doorbell: true when the reader may wait (the writer
  // rings for its next frame); false when a frame came meanwhile (drain again).
  bool Park() {
    ring_.Parked().store(1, std::memory_order_seq_cst);
    if (ring_.Tail().load(std::memory_order_seq_cst) == head_) return true;
    ring_.Parked().store(0, std::memory_order_relaxed);
    return false;
  }

  // After a wake: the writer cleared `parked` when it rang; a wake from
  // elsewhere (the host's own, after a refusal) leaves it set.
  void Unpark() { ring_.Parked().store(0, std::memory_order_relaxed); }

  // Drains into `sink`, calls `flush()` (hand on what the sink took), parks
  // and waits on `doorbell` (`Wake Wait()`), until the doorbell stops or
  // fails or the ring breaks. A refused frame waits, unparked, for the sink's
  // owner to ring `doorbell` once it takes frames again.
  template <typename Doorbell, typename Sink, typename Flush>
  End Run(Doorbell& doorbell, Sink&& sink, Flush&& flush) {
    Wake wake;
    do {
      Unpark();
      Drained drained;
      do {
        drained = Drain(sink);
        if (drained == Drained::kBroken) return End::kBroken;
        flush();
      } while (drained == Drained::kEmpty && !Park());
      wake = doorbell.Wait();  // blocks until a ring, Stop or a failure: no spin
    } while (wake == Wake::kRung);
    return wake == Wake::kStopped ? End::kStopped : End::kDoorbellFailed;
  }

 private:
  Ring ring_;
  uint64_t head_;
};

#if defined(__APPLE__)
// Sends one empty message to `port` without waiting: true when it was sent
// or a doorbell already waits (the queue limit is 1), false when the port is
// dead. The writer's ring (cmux_input_ring_doorbell_ring in cmux is the same).
inline bool RingPort(mach_port_t port) {
  mach_msg_empty_send_t message = {};
  message.header.msgh_bits = MACH_MSGH_BITS_REMOTE(MACH_MSG_TYPE_COPY_SEND);
  message.header.msgh_size = sizeof message;
  message.header.msgh_remote_port = port;
  const kern_return_t result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0,
                                        MACH_PORT_NULL, 0, MACH_PORT_NULL);
  return result == MACH_MSG_SUCCESS || result == MACH_SEND_TIMED_OUT;
}

// The host's doorbell: the receive right checked in under cmux's name, with a
// queue limit of 1, waited on in a kqueue. Wait on the reader thread; Ring
// and Stop from any thread.
class MachDoorbell {
 public:
  MachDoorbell() = default;
  MachDoorbell(const MachDoorbell&) = delete;
  MachDoorbell& operator=(const MachDoorbell&) = delete;
  ~MachDoorbell() {
    if (kqueue_ >= 0) ::close(kqueue_);
    if (port_ != MACH_PORT_NULL) {
      mach_port_mod_refs(mach_task_self(), port_, MACH_PORT_RIGHT_RECEIVE, -1);
      mach_port_deallocate(mach_task_self(), port_);  // the send right Ring uses
    }
  }

  // False when `name` cannot be checked in or the kqueue cannot be made.
  bool CheckIn(const char* name) {
    const task_t task = mach_task_self();
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_check_in(bootstrap_port, name, &port) != KERN_SUCCESS) return false;
    mach_port_limits_t limits = {};
    limits.mpl_qlimit = 1;
    if (mach_port_set_attributes(task, port, MACH_PORT_LIMITS_INFO, reinterpret_cast<mach_port_info_t>(&limits),
                                 MACH_PORT_LIMITS_INFO_COUNT) != KERN_SUCCESS ||
        mach_port_insert_right(task, port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
      mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1);
      return false;
    }
    port_ = port;
    kqueue_ = ::kqueue();
    if (kqueue_ < 0) return false;
    kevent64_s events[2] = {};
    events[0].ident = port_;
    events[0].filter = EVFILT_MACHPORT;
    events[0].flags = EV_ADD;
    events[0].fflags = MACH_RCV_MSG;  // the kevent receives the message into buffer_
    events[0].ext[0] = reinterpret_cast<uint64_t>(&buffer_);
    events[0].ext[1] = sizeof buffer_;
    events[1].ident = kStopIdent;
    events[1].filter = EVFILT_USER;
    events[1].flags = EV_ADD | EV_CLEAR;
    return kevent64(kqueue_, events, 2, nullptr, 0, 0, nullptr) == 0;
  }

  // Waits for a ring or Stop. kFailed when the kqueue failed: the reader
  // would never wake again, and its owner ends the host.
  Wake Wait() {
    kevent64_s event = {};
    int count;
    do count = kevent64(kqueue_, nullptr, 0, &event, 1, 0, nullptr);
    while (count < 0 && errno == EINTR);
    if (count != 1 || (event.flags & EV_ERROR) != 0) return Wake::kFailed;
    return event.filter == EVFILT_USER ? Wake::kStopped : Wake::kRung;
  }

  // The host's own ring (its UI thread ran a batch, so a refused frame can go).
  bool Ring() const { return RingPort(port_); }

  void Stop() {
    kevent64_s event = {};
    event.ident = kStopIdent;
    event.filter = EVFILT_USER;
    event.fflags = NOTE_TRIGGER;
    kevent64(kqueue_, &event, 1, nullptr, 0, 0, nullptr);
  }

 private:
  static constexpr uint64_t kStopIdent = 1;
  mach_port_t port_ = MACH_PORT_NULL;
  int kqueue_ = -1;
  mach_msg_empty_rcv_t buffer_ = {};
};

// Starts the calling thread as the reader: its label, and QoS
// user-interactive (input is what a person waits on). It stays there: the
// doorbell's message overrides no QoS of a thread waiting in a plain kqueue.
inline void BecomeReaderThread() {
  pthread_setname_np(kReaderLabel);
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}
#else
// Elsewhere (the tests on Linux) the reader keeps the default.
inline void BecomeReaderThread() {}
#endif

// Maps the ring cmux passed on `fd` (kRingFd in the host) and closes `fd`:
// nullptr when it is not a ring of this layout. UnmapRegion undoes it.
inline void* MapRegion(int fd) {
  struct stat region;
  const bool sized = fstat(fd, &region) == 0 && region.st_size >= static_cast<off_t>(kRingBytes);
  void* mapping = sized ? mmap(nullptr, kRingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
  ::close(fd);  // the mapping keeps the region
  if (mapping == MAP_FAILED) return nullptr;
  if (!Ring::Valid(mapping, kRingBytes)) {
    munmap(mapping, kRingBytes);
    return nullptr;
  }
  return mapping;
}
inline void UnmapRegion(void* mapping) {
  if (mapping != nullptr) munmap(mapping, kRingBytes);
}

// The hand-off of ring frames to the UI thread, one batch at a time: while a
// batch waits for the UI thread, Take refuses, so the frames stay in the ring,
// a full ring makes cmux keep the rest on its side, and nothing here grows.
class BatchGate {
 public:
  using Frames = std::vector<Header>;

  // The reader thread: false while a batch waits for the UI thread.
  bool Take(const Header& frame) {
    if (in_flight_.load(std::memory_order_acquire)) return false;
    batch_.push_back(frame);
    return true;
  }

  // The reader thread, after each drain: true, with the batch in `out`
  // (empty before), when one is ready for the UI thread.
  bool Flush(Frames* out) {
    if (batch_.empty() || in_flight_.load(std::memory_order_acquire)) return false;
    in_flight_.store(true, std::memory_order_release);
    out->swap(batch_);
    return true;
  }

  // The UI thread, after it ran the batch; then it rings the doorbell, which
  // wakes a reader that a refusal left waiting.
  void Done() { in_flight_.store(false, std::memory_order_release); }

 private:
  Frames batch_;                        // the reader thread's
  std::atomic<bool> in_flight_{false};  // a batch waits for the UI thread
};

// The host's input reader: a thread that waits on `doorbell`, takes the
// frames cmux wrote and hands them to the UI thread one batch at a time
// (BatchGate) through `post`. The host posts on Chromium's user-input queue
// once it runs (cmux_shim_post_user_input_task, BrowserTaskType::kUserInput in
// content/public/browser/browser_task_traits.h) and on its main run loop
// before. `Doorbell` is MachDoorbell in the host: `Wake Wait()` on the reader
// thread, `bool Ring() const` and `void Stop()` from any thread. The object,
// the mapping and the doorbell outlive every task it posted.
//
// The UI thread may take a batch only in part (the host's ordered stream is
// full while its frames wait for a control message, task 092): the rest stays
// here and the gate stays shut, so later frames stay in the ring and a full
// ring makes cmux keep them on its side. Retry offers the rest again.
template <typename Doorbell>
class HostInput {
 public:
  using Frames = BatchGate::Frames;
  // Runs a task on the UI thread, in post order. Any thread.
  using Post = std::function<void(std::function<void()>)>;
  // On the UI thread: takes `frames` from index `from`, oldest first, and returns how many it
  // took; fewer than the rest leaves them for the next Retry.
  using Deliver = std::function<size_t(const Frames& frames, size_t from)>;
  // On the UI thread, when the reader ended without Stop (End::kBroken or
  // End::kDoorbellFailed): the host can no longer take input, and ends.
  using Ended = std::function<void(Reader::End)>;

  HostInput(void* mapping, Doorbell& doorbell) : mapping_(mapping), doorbell_(doorbell) {}
  HostInput(const HostInput&) = delete;
  HostInput& operator=(const HostInput&) = delete;
  ~HostInput() { Stop(); }

  void Start(Post post, Deliver deliver, Ended ended) {
    post_ = std::move(post);
    deliver_ = std::move(deliver);
    ended_ = std::move(ended);
    thread_ = std::thread([this] {
      BecomeReaderThread();
      Reader reader(mapping_);
      const Reader::End end = reader.Run(
          doorbell_, [this](const Header& frame) { return gate_.Take(frame); }, [this] { Flush(); });
      if (end == Reader::End::kStopped) return;
      post_([this, end] {
        if (!stopped_.load(std::memory_order_acquire)) ended_(end);
      });
    });
  }

  // The UI thread: offers the rest of a batch taken in part again (after
  // what it waited for arrived). Nothing when no batch waits.
  void Retry() {
    if (stopped_.load(std::memory_order_acquire) || held_.empty()) return;
    Offer();
  }

  // The UI thread: frames of a batch taken in part that wait here.
  size_t held() const { return held_.size() - held_from_; }

  // The UI thread: ends the reader; batches that have not run are dropped.
  void Stop() {
    if (!thread_.joinable()) return;
    stopped_.store(true, std::memory_order_release);
    doorbell_.Stop();
    thread_.join();
  }

 private:
  // The reader thread, after each drain.
  void Flush() {
    Frames frames;
    if (!gate_.Flush(&frames)) return;
    post_([this, frames = std::move(frames)]() mutable {
      if (stopped_.load(std::memory_order_acquire)) return;
      held_ = std::move(frames);
      held_from_ = 0;
      Offer();
    });
  }

  // The UI thread: hands the held batch on; once all of it is taken the gate
  // opens and the reader, which a refusal may have left waiting, is rung.
  void Offer() {
    held_from_ += deliver_(held_, held_from_);
    if (held_from_ < held_.size()) return;
    held_.clear();
    held_from_ = 0;
    gate_.Done();
    doorbell_.Ring();
  }

  void* const mapping_;
  Doorbell& doorbell_;
  BatchGate gate_;
  std::thread thread_;
  Post post_;
  Deliver deliver_;
  Ended ended_;
  Frames held_;            // the UI thread's: the batch being taken
  size_t held_from_ = 0;   // the UI thread's: its first frame not taken yet
  std::atomic<bool> stopped_{false};
};

}  // namespace cmux_host::input_ring
