// The input ring (chromium_host_input_ring.h): its golden bytes (the same as
// ChromiumHostInputRingTests.swift checks), full and broken rings, the park
// protocol, how the reader ends, the host reader's back-pressure handshake
// (HostInput: a batch in flight refuses, the UI thread's ring takes the reader
// on) over 1,000,000 frames, and a process pair that moves 1,000,000 frames
// with no loss and in order. Run by
// scripts/cmux-next/tests/chromium-host-input-ring.test.sh; on macOS the
// doorbell is the real Mach port, elsewhere a pipe.
#include "../src/chromium_host_input_ring.h"

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
    input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); }, [](const HostInput<FixedDoorbell>::Frames&) {},
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
      input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); }, [](const auto&) {},
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
  std::atomic<bool> ended{false};
  Input input(mapping.base, local.get());
  input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); },
              [&](const Input::Frames& frames) {
                ++batches;
                largest = std::max(largest, frames.size());
                for (const Header& frame : frames) {
                  ordered = ordered && frame.seq == expected && frame.t0 == expected;
                  ++expected;
                }
                if (batches % 64 == 0) std::this_thread::yield();  // a UI thread that is sometimes busy
                if (expected > kFrames) {
                  std::lock_guard<std::mutex> lock(mutex);
                  done = true;
                  ready.notify_one();
                }
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
  std::printf("input ring host reader: %u frames, %llu batches (largest %zu), %llu writes found the ring full\n", kFrames,
              static_cast<unsigned long long>(batches), largest, static_cast<unsigned long long>(full));
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
  if (failures != 0) {
    std::fprintf(stderr, "%d failures\n", failures);
    return 1;
  }
  std::printf("chromium_host_input_ring_test: ok\n");
  return 0;
}
