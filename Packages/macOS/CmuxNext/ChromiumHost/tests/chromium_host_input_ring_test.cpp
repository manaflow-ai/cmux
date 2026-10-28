// The input ring (chromium_host_input_ring.h): its golden bytes (the same as
// ChromiumHostInputRingTests.swift checks), full and broken rings, the park
// protocol, how the reader ends, the host reader's back-pressure handshake
// (HostInput: a batch in flight refuses, the UI thread's ring takes the reader
// on) over 1,000,000 frames, and a process pair that moves 1,000,000 frames
// with no loss and in order, and the acks the host sends for a dispatched batch (AckBatch,
// host_input.h). Run by
// scripts/cmux-next/tests/chromium-host-input-ring.test.sh; on macOS the
// doorbell is the real Mach port, elsewhere a pipe.
#include "../src/chromium_host_input_ring.h"
#include "../src/host_input.h"

#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "../src/host_user_input.h"
#include "chromium_host_input_ring_test_support.h"

using cmux_host::Header;
using namespace cmux_host::input_ring;
using cmux_host::input_ring::testing::TaskThread;

namespace {

int failures = 0;

#define EXPECT(condition)                                               \
  do {                                                                  \
    if (!(condition)) {                                                 \
      std::fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
      ++failures;                                                       \
    }                                                                   \
  } while (0)

constexpr auto kStallLimit = std::chrono::seconds(60);

std::vector<uint8_t> Hex(const char* hex) {
  std::vector<uint8_t> bytes;
  for (const char* at = hex; at[0] && at[1]; at += 2) bytes.push_back(static_cast<uint8_t>(std::stoul(std::string(at, 2), nullptr, 16)));
  return bytes;
}

// The ring's first 16 bytes after Format, and the golden key frame in slot 0
// (ChromiumHostInputRingTests.goldenHeader / goldenFrame).
const char* const kGoldenHeader = "434d4952010000000010000040000000";
const char* const kGoldenFrame =
    "0500000000000000000000002400000000000000000000000000000000000000"
    "0000100000000000080706050403020107000000000000000d000d0001000000";

Header GoldenKey() {
  Header header;
  header.kind = cmux_host::kKey;
  header.v[1] = 0x24;  // Return
  header.flags = 0x100000;
  header.t0 = 0x0102030405060708;
  header.ch = 0x0d;
  header.unmod = 0x0d;
  header.seq = 1;
  SetBrowser(&header, 7);
  return header;
}

Header Numbered(uint32_t seq) {
  Header header;
  header.kind = cmux_host::kKey;
  header.seq = seq;
  header.t0 = seq;
  return header;
}

struct Mapping {
  void* base;
  Mapping() {
    base = mmap(nullptr, kRingBytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) std::abort();
    Ring::Format(base);
  }
  ~Mapping() { munmap(base, kRingBytes); }
  const uint8_t* bytes() const { return static_cast<const uint8_t*>(base); }
};

// A doorbell whose Wait returns `wake` at once; rings and stops do nothing.
struct FixedDoorbell {
  Wake wake;
  Wake Wait() { return wake; }
  bool Ring() const { return true; }
  void Stop() {}
};

// The doorbell of an in-process reader, and the writer's ring of it: the real
// Mach port on macOS (checked in under a name of this process), a pipe elsewhere.
#if defined(__APPLE__)
struct LocalDoorbell {
  using Doorbell = MachDoorbell;
  MachDoorbell doorbell;
  bool ready;
  explicit LocalDoorbell(const char* test) {
    const std::string name = std::string("com.cmuxterm.chromium-host.input-ring-test.") + test + "." + std::to_string(getpid());
    ready = doorbell.CheckIn(name.c_str());
  }
  Doorbell& get() { return doorbell; }
  void RingFromWriter() { doorbell.Ring(); }
};
#else
struct LocalDoorbell {
  using Doorbell = testing::PipeDoorbell;
  int bell[2] = {-1, -1};
  std::unique_ptr<testing::PipeDoorbell> doorbell;
  bool ready;
  explicit LocalDoorbell(const char*) {
    ready = pipe(bell) == 0;
    if (ready) doorbell = std::make_unique<testing::PipeDoorbell>(bell[0], bell[1]);
  }
  ~LocalDoorbell() {
    doorbell.reset();
    for (int fd : bell) {
      if (fd >= 0) close(fd);
    }
  }
  Doorbell& get() { return *doorbell; }
  void RingFromWriter() { doorbell->Ring(); }
};
#endif

void TestLayout() {
  EXPECT(kRingBytes == 512 + 4096 * 64);
  Mapping mapping;
  EXPECT(Ring::Valid(mapping.base, kRingBytes));
  EXPECT(!Ring::Valid(mapping.base, kRingBytes - 1));
  const std::vector<uint8_t> header = Hex(kGoldenHeader);
  EXPECT(std::memcmp(mapping.bytes(), header.data(), 16) == 0);
  Writer writer(mapping.base);
  EXPECT(writer.Write(GoldenKey()) == Writer::Push::kWritten);
  const std::vector<uint8_t> frame = Hex(kGoldenFrame);
  EXPECT(frame.size() == kFrameSize);
  EXPECT(std::memcmp(mapping.bytes() + kFramesOffset, frame.data(), kFrameSize) == 0);
  EXPECT(cmux_host::detail::Get<uint64_t>(mapping.bytes(), kTailOffset) == 1);
  Reader reader(mapping.base);
  Header read;
  EXPECT(reader.Drain([&read](const Header& h) {
    read = h;
    return true;
  }) == Reader::Drained::kEmpty);
  EXPECT(read.kind == cmux_host::kKey && read.v[1] == 0x24 && BrowserOf(read) == 7 && read.seq == 1 &&
         read.t0 == 0x0102030405060708);
  EXPECT(cmux_host::detail::Get<uint64_t>(mapping.bytes(), kHeadOffset) == 1);
}

void TestFullAndRefused() {
  Mapping mapping;
  Writer writer(mapping.base);
  for (uint32_t seq = 1; seq <= kCapacity; ++seq) EXPECT(writer.Write(Numbered(seq)) == Writer::Push::kWritten);
  EXPECT(writer.Write(Numbered(0)) == Writer::Push::kFull);
  Reader reader(mapping.base);
  uint32_t taken = 0;
  // The sink takes two and refuses the third: it stays first.
  EXPECT(reader.Drain([&taken](const Header&) { return ++taken <= 2; }) == Reader::Drained::kRefused);
  EXPECT(cmux_host::detail::Get<uint64_t>(mapping.bytes(), kHeadOffset) == 2);
  EXPECT(writer.Write(Numbered(kCapacity + 1)) == Writer::Push::kWritten);
  EXPECT(writer.Write(Numbered(kCapacity + 2)) == Writer::Push::kWritten);
  EXPECT(writer.Write(Numbered(0)) == Writer::Push::kFull);
  uint32_t expected = 3;
  bool ordered = true;
  EXPECT(reader.Drain([&](const Header& h) {
    ordered = ordered && h.seq == expected++;
    return true;
  }) == Reader::Drained::kEmpty);
  EXPECT(ordered && expected == kCapacity + 3);
}

void TestBroken() {
  {
    Mapping mapping;
    Writer writer(mapping.base);
    for (uint64_t i = 0; i < kCapacity; ++i) writer.Write(Numbered(1));
    Ring(mapping.base).Head().store(kCapacity + 5);  // a head past the tail
    EXPECT(writer.Write(Numbered(1)) == Writer::Push::kBroken);
  }
  {
    Mapping mapping;
    Ring(mapping.base).Tail().store(kCapacity + 1);  // more frames than slots
    Reader reader(mapping.base);
    EXPECT(reader.Drain([](const Header&) { return true; }) == Reader::Drained::kBroken);
  }
  {
    Mapping mapping;
    Header with_payload = Numbered(1);
    with_payload.payload = 3;  // ring frames carry none
    Writer(mapping.base).Write(with_payload);
    Reader reader(mapping.base);
    EXPECT(reader.Drain([](const Header&) { return true; }) == Reader::Drained::kBroken);
  }
}

void TestPark() {
  Mapping mapping;
  Writer writer(mapping.base);
  Reader reader(mapping.base);
  EXPECT(reader.Park());
  EXPECT(writer.Write(Numbered(1)) == Writer::Push::kWrittenRing);
  EXPECT(writer.Write(Numbered(2)) == Writer::Push::kWritten);  // one ring per park
  EXPECT(!reader.Park());                                          // frames wait: drain first
  EXPECT(writer.Write(Numbered(3)) == Writer::Push::kWritten);
}

// Run ends on a stop, a failed doorbell (never as a stop: before the fix a
// failed kqueue looked like Stop and the host lost its input with no report)
// and a broken ring.
void TestRunEnds() {
  auto take = [](const Header&) { return true; };
  auto flush = [] {};
  {
    Mapping mapping;
    FixedDoorbell doorbell{Wake::kStopped};
    EXPECT(Reader(mapping.base).Run(doorbell, take, flush) == Reader::End::kStopped);
  }
  {
    Mapping mapping;
    FixedDoorbell doorbell{Wake::kFailed};
    EXPECT(Reader(mapping.base).Run(doorbell, take, flush) == Reader::End::kDoorbellFailed);
  }
  {
    Mapping mapping;
    Ring(mapping.base).Tail().store(kCapacity + 1);
    FixedDoorbell doorbell{Wake::kRung};
    EXPECT(Reader(mapping.base).Run(doorbell, take, flush) == Reader::End::kBroken);
  }
}

// HostInput reports a reader that ended without Stop on the UI thread, and
// nothing after Stop.
void TestHostInputReportsItsEnd() {
  for (const Wake wake : {Wake::kFailed, Wake::kRung}) {
    Mapping mapping;
    if (wake == Wake::kRung) Ring(mapping.base).Tail().store(kCapacity + 1);  // broken
    FixedDoorbell doorbell{wake};
    TaskThread ui;
    std::mutex mutex;
    std::condition_variable ready;
    bool ended = false;
    Reader::End end = Reader::End::kStopped;
    HostInput<FixedDoorbell> input(mapping.base, doorbell);
    input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); }, [](const HostInput<FixedDoorbell>::Frames& frames, size_t) { return frames.size(); },
                [&](Reader::End reported) {
                  std::lock_guard<std::mutex> lock(mutex);
                  ended = true;
                  end = reported;
                  ready.notify_one();
                });
    EXPECT(testing::WaitFor(mutex, ready, kStallLimit, [&] { return ended; }));
    EXPECT(end == (wake == Wake::kFailed ? Reader::End::kDoorbellFailed : Reader::End::kBroken));
    input.Stop();
    ui.Stop();  // the tasks still posted run while `input` lives
  }
  {
    Mapping mapping;
    LocalDoorbell local("stop");
    EXPECT(local.ready);
    if (!local.ready) return;
    TaskThread ui;
    std::atomic<bool> ended{false};
    {
      HostInput<LocalDoorbell::Doorbell> input(mapping.base, local.get());
      input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); }, [](const auto& frames, size_t) { return frames.size(); },
                  [&ended](Reader::End) { ended = true; });
      input.Stop();
      ui.Stop();
    }
    EXPECT(!ended);
  }
}

// The back-pressure handshake: while a batch waits for the UI thread the
// reader refuses and waits unparked; only the UI thread's ring after the
// batch takes it on. 1,000,000 frames from a writer that keeps writing reach
// the UI thread in order, with no stall.
void TestHostInputBackPressure() {
  constexpr uint32_t kFrames = 1000000;
  Mapping mapping;
  LocalDoorbell local("back-pressure");
  EXPECT(local.ready);
  if (!local.ready) return;
  using Input = HostInput<LocalDoorbell::Doorbell>;
  TaskThread ui;
  std::mutex mutex;
  std::condition_variable ready;
  bool done = false;
  uint32_t expected = 1;  // the UI thread's
  bool ordered = true;
  uint64_t batches = 0;
  size_t largest = 0;
  uint64_t partial = 0;  // offers taken in part
  std::atomic<bool> ended{false};
  Input input(mapping.base, local.get());
  input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); },
              [&](const Input::Frames& frames, size_t from) -> size_t {
                ++batches;
                largest = std::max(largest, frames.size());
                // Every third offer takes only half of what is left, as the host's ordered stream
                // does while it is full, and the rest comes back on a later Retry (the next
                // control message): the frames still arrive once each, in order.
                size_t take = frames.size() - from;
                if (batches % 3 == 0 && take > 1) {
                  take /= 2;
                  ++partial;
                  ui.Post([&input] { input.Retry(); });
                }
                for (size_t index = from; index < from + take; ++index) {
                  ordered = ordered && frames[index].seq == expected && frames[index].t0 == expected;
                  ++expected;
                }
                if (batches % 64 == 0) std::this_thread::yield();  // a UI thread that is sometimes busy
                if (expected > kFrames) {
                  std::lock_guard<std::mutex> lock(mutex);
                  done = true;
                  ready.notify_one();
                }
                return take;
              },
              [&ended](Reader::End) { ended = true; });
  Writer writer(mapping.base);
  uint64_t full = 0;
  const auto deadline = std::chrono::steady_clock::now() + kStallLimit;
  bool stalled = false;
  for (uint32_t seq = 1; seq <= kFrames && !stalled; ++seq) {
    for (;;) {
      const Writer::Push push = writer.Write(Numbered(seq));
      if (push == Writer::Push::kFull) {
        ++full;  // cmux spills to its backlog instead; the test waits for room
        if ((full & 0xfff) == 0 && std::chrono::steady_clock::now() > deadline) {
          stalled = true;
          break;
        }
        sched_yield();
        continue;
      }
      EXPECT(push != Writer::Push::kBroken);
      if (push == Writer::Push::kWrittenRing) local.RingFromWriter();
      break;
    }
  }
  EXPECT(!stalled);
  EXPECT(testing::WaitFor(mutex, ready, kStallLimit, [&] { return done; }));
  input.Stop();
  ui.Stop();
  EXPECT(ordered && expected == kFrames + 1);
  EXPECT(!ended);
  EXPECT(partial > 0);
  std::printf("input ring host reader: %u frames, %llu offers (%llu taken in part, largest %zu), %llu writes found the ring full\n", kFrames,
              static_cast<unsigned long long>(batches), static_cast<unsigned long long>(partial), largest,
              static_cast<unsigned long long>(full));
}

// HostInput with the host's InputTasks as its Post, as browser_host_main.mm
// starts it (task p01-process-042 with p04-input-065): batches before Start
// run on the main run loop, after it on the chosen user-input queue and never
// on the fallback, in order across the switch. Once the UI thread is shut down
// its queue refuses: the batch is dropped, the gate stays shut, no later batch
// is posted to any queue, and Stop ends the reader.
void TestHostInputThroughInputTasks() {
  constexpr uint32_t kBeforeStart = 3000;
  constexpr uint32_t kAfterStart = 3000;
  constexpr uint32_t kAtShutdown = 20;
  Mapping mapping;
  LocalDoorbell local("input-tasks");
  EXPECT(local.ready);
  if (!local.ready) return;
  using Input = HostInput<LocalDoorbell::Doorbell>;
  using cmux_host::InputTasks;
  TaskThread main_loop;
  TaskThread user_input;
  std::mutex mutex;
  std::condition_variable ready;
  uint32_t delivered = 0;  // under `mutex`, as the rest of this block
  bool ordered = true;
  uint64_t main_posts = 0, user_input_posts = 0, fallback_posts = 0, refused = 0;
  bool shut_down = false;
  auto count = [&](uint64_t* posts) {
    std::lock_guard<std::mutex> lock(mutex);
    ++*posts;
    ready.notify_one();
  };
  InputTasks tasks(
      [&](InputTasks::Task task) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          if (shut_down) {
            ++refused;
            ready.notify_one();
            return;  // `task` is freed unrun, as a refused CefTask is
          }
          ++user_input_posts;
        }
        user_input.Post(std::move(task));
      },
      [&](InputTasks::Task task) {
        count(&fallback_posts);
        user_input.Post(std::move(task));
      },
      [&](InputTasks::Task task) {
        count(&main_posts);
        main_loop.Post(std::move(task));
      });
  Input input(mapping.base, local.get());
  std::atomic<bool> ended{false};
  // `from...`: task 042's Deliver also takes the index to start from and returns how many it took.
  input.Start([&tasks](std::function<void()> task) { tasks.Post(std::move(task)); },
              [&](const Input::Frames& frames, auto... from) -> size_t {
                const size_t first = (size_t{0} + ... + from);
                std::lock_guard<std::mutex> lock(mutex);
                for (size_t i = first; i < frames.size(); ++i) {
                  ordered = ordered && frames[i].seq == delivered + 1;
                  ++delivered;
                }
                ready.notify_one();
                return frames.size() - first;
              },
              [&ended](Reader::End) { ended = true; });
  Writer writer(mapping.base);
  uint32_t seq = 0;
  auto write = [&](uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
      const Writer::Push push = writer.Write(Numbered(++seq));
      EXPECT(push != Writer::Push::kFull && push != Writer::Push::kBroken);
      if (push == Writer::Push::kWrittenRing) local.RingFromWriter();
    }
  };
  auto delivered_all = [&] { return delivered == seq; };

  write(kBeforeStart);
  EXPECT(testing::WaitFor(mutex, ready, kStallLimit, delivered_all));
  uint64_t main_posts_at_start = 0;
  {
    std::lock_guard<std::mutex> lock(mutex);
    main_posts_at_start = main_posts;
    EXPECT(main_posts > 0 && user_input_posts == 0);
  }
  tasks.Start();
  write(kAfterStart);
  EXPECT(testing::WaitFor(mutex, ready, kStallLimit, delivered_all));
  {
    std::lock_guard<std::mutex> lock(mutex);
    EXPECT(ordered && delivered == kBeforeStart + kAfterStart);
    EXPECT(user_input_posts > 0 && main_posts == main_posts_at_start && fallback_posts == 0);
    shut_down = true;
  }
  write(kAtShutdown);
  EXPECT(testing::WaitFor(mutex, ready, kStallLimit, [&] { return refused > 0; }));
  write(kAtShutdown);  // they stay in the ring: the dropped batch keeps the gate shut
  input.Stop();
  const uint64_t head = Ring(mapping.base).Head().load(std::memory_order_acquire);
  main_loop.Stop();
  user_input.Stop();
  std::lock_guard<std::mutex> lock(mutex);
  EXPECT(refused == 1 && delivered == kBeforeStart + kAfterStart);
  EXPECT(main_posts == main_posts_at_start && fallback_posts == 0);
  EXPECT(head <= kBeforeStart + kAfterStart + kAtShutdown);
  EXPECT(!ended);
}

void TestProcessPair() {
  constexpr uint32_t kFrames = 1000000;
  Mapping mapping;
  int ready[2];
  int bell[2];
  if (pipe(ready) != 0 || pipe(bell) != 0) std::abort();
#if defined(__APPLE__)
  const std::string name = "com.cmuxterm.chromium-host.input-ring-test." + std::to_string(getpid());
#endif
  std::fflush(stdout);  // the child must not print this process's buffered lines again
  const pid_t child = fork();
  if (child < 0) std::abort();
  if (child == 0) {
    close(ready[0]);
    close(bell[1]);  // the parent's death is EOF on the bell: Wake::kFailed
#if defined(__APPLE__)
    MachDoorbell doorbell;
    if (!doorbell.CheckIn(name.c_str())) _exit(3);
    BecomeReaderThread();
#else
    testing::PipeDoorbell doorbell(bell[0], -1);
#endif
    if (write(ready[1], "r", 1) != 1) _exit(4);
    Reader reader(mapping.base);
    uint32_t expected = 1;
    bool ordered = true;
    const Reader::End end = reader.Run(
        doorbell,
        [&](const Header& h) {
          ordered = ordered && h.seq == expected && h.t0 == expected;
          if (++expected > kFrames) doorbell.Stop();
          return true;
        },
        [] {});
    _exit(end == Reader::End::kStopped && ordered && expected == kFrames + 1 ? 0 : 1);
  }
  // Only the child's copies stay open: its early exit is EOF here, not a hang.
  close(ready[1]);
  close(bell[0]);
  char byte;
  const bool started = read(ready[0], &byte, 1) == 1;
  close(ready[0]);
  EXPECT(started);
  int status = 0;
  bool reaped = false;
  uint64_t rings = 0;
  uint64_t full = 0;
  if (started) {
#if defined(__APPLE__)
    mach_port_t port = MACH_PORT_NULL;
    EXPECT(bootstrap_look_up(bootstrap_port, name.c_str(), &port) == KERN_SUCCESS);
    auto ring = [port] { RingPort(port); };
#else
    fcntl(bell[1], F_SETFL, O_NONBLOCK);
    auto ring = [&bell] { (void)!write(bell[1], "d", 1); };
#endif
    Writer writer(mapping.base);
    for (uint32_t seq = 1; seq <= kFrames && !reaped; ++seq) {
      for (;;) {
        const Writer::Push push = writer.Write(Numbered(seq));
        if (push == Writer::Push::kFull) {
          ++full;  // the test waits for space; cmux spills instead
          if (waitpid(child, &status, WNOHANG) == child) {
            reaped = true;  // the reader died: the ring never empties
            break;
          }
          sched_yield();
          continue;
        }
        EXPECT(push != Writer::Push::kBroken);
        if (push == Writer::Push::kWrittenRing) {
          ++rings;
          ring();
        }
        break;
      }
    }
  }
  close(bell[1]);
  if (!reaped) EXPECT(waitpid(child, &status, 0) == child);
  EXPECT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  std::printf("input ring pair: %u frames, %llu doorbells, %llu writes found the ring full\n", kFrames,
              static_cast<unsigned long long>(rings), static_cast<unsigned long long>(full));
}

// A batch's acks: one record per pointer move and wheel tick (the frames cmux paces), in batch
// order, with the client browser and the frame's seq; keys, clicks and exits get none.
void TestAckBatch() {
  auto frame = [](uint32_t kind, int32_t phase, int32_t browser, uint32_t seq) {
    Header h;
    h.kind = kind;
    h.v[kind == cmux_host::kKey ? 0 : 2] = phase;
    SetBrowser(&h, browser);
    h.seq = seq;
    return h;
  };
  cmux_host::AckBatch acks;
  EXPECT(acks.empty());
  acks.Add(frame(cmux_host::kKey, 0, 7, 1));
  acks.Add(frame(cmux_host::kMouse, 0, 7, 2));    // move
  acks.Add(frame(cmux_host::kMouse, 1, 7, 3));    // down
  acks.Add(frame(cmux_host::kWheel, 3, 9, 4));    // wheel tick, phase changed
  acks.Add(frame(cmux_host::kMouse, 3, 7, 5));    // exit
  acks.Add(frame(cmux_host::kMouse, 0, -2, 6));   // a move of a page with a negative client id
  EXPECT(acks.count() == 3);
  const cmux_host::control::Message message = acks.Take();
  EXPECT(acks.empty());
  EXPECT(message.op == cmux_host::control::kOpInputAck && !message.reply && message.token == 0);
  cmux_host::control::TlvReader r(message.fields);
  EXPECT(r.I32() == 7 && r.I32() == static_cast<int32_t>(cmux_host::kMouse) && r.U32() == 2);
  EXPECT(r.I32() == 9 && r.I32() == static_cast<int32_t>(cmux_host::kWheel) && r.U32() == 4);
  EXPECT(r.I32() == -2 && r.I32() == static_cast<int32_t>(cmux_host::kMouse) && r.U32() == 6);
  EXPECT(r.ok() && r.AtEnd());
  // The next batch starts empty.
  acks.Add(frame(cmux_host::kWheel, 4, 9, 8));
  const cmux_host::control::Message next = acks.Take();
  EXPECT(next.fields.size() == 3);
}

// The host's ring input on the ordered stream (OrderedInput, tasks 042 and 092): a frame waits
// while input is closed (before initialize) and while the control message it names is not
// applied; it is dispatched, and its move acked, only once that message ran, never before.
// A full stream takes a batch in part; the rest comes in again after the next control message.
void TestOrderedInputDispatchesAndAcksAfterItsControlMessage() {
  using cmux_host::control::Message;
  using cmux_host::control::OrderedStream;
  std::vector<std::string> log;  // what ran, in order: "ctl N" or "frame N"
  std::vector<Message> acks;
  const char* malformed = nullptr;
  OrderedStream::Limits limits;
  limits.held_input = 2;
  OrderedStream stream(
      [&log](std::vector<Message> run) {
        for (const Message& message : run) log.push_back("ctl " + std::to_string(message.ctl_seq));
      },
      limits);
  cmux_host::OrderedInput input(
      stream, [&log](const Header& frame) { log.push_back("frame " + std::to_string(frame.seq)); },
      [&acks](Message message) { acks.push_back(std::move(message)); },
      [&malformed](const char* what) { malformed = what; });
  auto move = [](uint32_t seq, uint32_t ctl_seq) {
    Header h;
    h.kind = cmux_host::kMouse;  // v[2] 0: a move, which cmux paces and the host acks
    h.seq = seq;
    SetBrowser(&h, 7);
    cmux_host::SetCtlSeq(&h, ctl_seq);
    return h;
  };
  auto control = [](uint32_t ctl_seq) {
    Message message;
    message.op = 1;
    message.ctl_seq = ctl_seq;
    return message;
  };
  auto acked = [&acks]() {
    std::vector<uint32_t> seqs;
    for (const Message& message : acks) {
      cmux_host::control::TlvReader r(message.fields);
      while (!r.AtEnd() && r.ok()) {
        r.I32();
        r.I32();
        seqs.push_back(r.U32());
      }
    }
    return seqs;
  };

  // Before initialize: the frame is taken but waits, unacked.
  EXPECT(input.Take({move(1, 0)}, 0) == 1);
  EXPECT(log.empty() && acks.empty());
  input.After(stream.OpenInput());
  EXPECT(log == std::vector<std::string>{"frame 1"});
  EXPECT(acked() == std::vector<uint32_t>{1});

  // A frame written after control message 5 waits for it: not dispatched, not acked.
  EXPECT(input.Take({move(2, 5)}, 0) == 1);
  EXPECT(log.size() == 1 && acked().size() == 1);
  input.After(stream.AddControl({control(5)}));
  EXPECT((log == std::vector<std::string>{"frame 1", "ctl 5", "frame 2"}));
  EXPECT((acked() == std::vector<uint32_t>{1, 2}));

  // A full stream (2 held) takes 2 of 3 frames that wait for message 9; the third goes in after it.
  const std::vector<Header> batch = {move(3, 9), move(4, 9), move(5, 9)};
  EXPECT(input.Take(batch, 0) == 2);
  EXPECT(log.size() == 3 && acked().size() == 2);
  input.After(stream.AddControl({control(9)}));
  EXPECT((log == std::vector<std::string>{"frame 1", "ctl 5", "frame 2", "ctl 9", "frame 3", "frame 4"}));
  EXPECT(input.Take(batch, 2) == 1);  // HostInput::Retry offers the rest
  EXPECT((acked() == std::vector<uint32_t>{1, 2, 3, 4, 5}));
  EXPECT(malformed == nullptr);

  // An input seq not after the one before is malformed: the host ends, and the batch counts as taken.
  EXPECT(input.Take({move(5, 0), move(6, 0)}, 0) == 2);
  EXPECT(malformed != nullptr);
}

}  // namespace

int main() {
  signal(SIGPIPE, SIG_IGN);  // a ring to a dead reader's pipe fails instead
  TestLayout();
  TestFullAndRefused();
  TestBroken();
  TestPark();
  TestRunEnds();
  TestHostInputReportsItsEnd();
  TestHostInputBackPressure();
  TestHostInputThroughInputTasks();
  TestProcessPair();
  TestAckBatch();
  TestOrderedInputDispatchesAndAcksAfterItsControlMessage();
  if (failures != 0) {
    std::fprintf(stderr, "%d failures\n", failures);
    return 1;
  }
  std::printf("chromium_host_input_ring_test: ok\n");
  return 0;
}
