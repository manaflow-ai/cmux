// The input ring (chromium_host_input_ring.h): its golden bytes (the same as
// ChromiumHostInputRingTests.swift checks), full and broken rings, the park
// protocol, and a process pair that moves 1,000,000 frames with no loss and
// in order. Run by scripts/cmux-next/tests/chromium-host-input-ring.test.sh;
// on macOS the pair rings the real Mach doorbell, elsewhere a pipe.
#include "../src/chromium_host_input_ring.h"

#include <fcntl.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using cmux_host::Header;
using namespace cmux_host::input_ring;

namespace {

int failures = 0;

#define EXPECT(condition)                                               \
  do {                                                                  \
    if (!(condition)) {                                                 \
      std::fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
      ++failures;                                                       \
    }                                                                   \
  } while (0)

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
  EXPECT(reader.Drain([&taken](const Header&) { return ++taken <= 2; }) == Reader::Drained::kStopped);
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

// The reader's doorbell in the pair: the real Mach port on macOS, a pipe elsewhere.
#if defined(__APPLE__)
using PairDoorbell = MachDoorbell;
#else
class PairDoorbell {
 public:
  explicit PairDoorbell(int read_fd) : read_fd_(read_fd) {}
  bool Wait() {
    if (stopped_) return false;
    char bytes[64];
    ssize_t count;
    do count = read(read_fd_, bytes, sizeof bytes);
    while (count < 0 && errno == EINTR);
    return count > 0 && !stopped_;
  }
  void Stop() { stopped_ = true; }

 private:
  int read_fd_;
  bool stopped_ = false;
};
#endif

void TestProcessPair() {
  constexpr uint32_t kFrames = 1000000;
  Mapping mapping;
  int ready[2];
  int bell[2];
  if (pipe(ready) != 0 || pipe(bell) != 0) std::abort();
#if defined(__APPLE__)
  const std::string name = "com.cmuxterm.chromium-host.input-ring-test." + std::to_string(getpid());
#endif
  const pid_t child = fork();
  if (child == 0) {
#if defined(__APPLE__)
    PairDoorbell doorbell;
    if (!doorbell.CheckIn(name.c_str())) _exit(3);
    BecomeReaderThread();
#else
    PairDoorbell doorbell(bell[0]);
#endif
    if (write(ready[1], "r", 1) != 1) _exit(4);
    Reader reader(mapping.base);
    uint32_t expected = 1;
    bool ordered = true;
    const Reader::Drained end = reader.Run(
        doorbell,
        [&](const Header& h) {
          ordered = ordered && h.seq == expected && h.t0 == expected;
          if (++expected > kFrames) doorbell.Stop();
          return true;
        },
        [] {});
    _exit(end == Reader::Drained::kStopped && ordered && expected == kFrames + 1 ? 0 : 1);
  }
  char byte;
  EXPECT(read(ready[0], &byte, 1) == 1);
#if defined(__APPLE__)
  mach_port_t port = MACH_PORT_NULL;
  EXPECT(bootstrap_look_up(bootstrap_port, name.c_str(), &port) == KERN_SUCCESS);
  auto ring = [port] { RingPort(port); };
#else
  fcntl(bell[1], F_SETFL, O_NONBLOCK);
  auto ring = [&bell] { (void)!write(bell[1], "d", 1); };
#endif
  Writer writer(mapping.base);
  uint64_t rings = 0;
  uint64_t full = 0;
  for (uint32_t seq = 1; seq <= kFrames; ++seq) {
    for (;;) {
      const Writer::Push push = writer.Write(Numbered(seq));
      if (push == Writer::Push::kFull) {
        ++full;  // the test waits for space; cmux spills instead
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
  int status = 0;
  EXPECT(waitpid(child, &status, 0) == child);
  EXPECT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  std::printf("input ring pair: %u frames, %llu doorbells, %llu writes found the ring full\n", kFrames,
              static_cast<unsigned long long>(rings), static_cast<unsigned long long>(full));
}

}  // namespace

int main() {
  TestLayout();
  TestFullAndRefused();
  TestBroken();
  TestPark();
  TestProcessPair();
  if (failures != 0) {
    std::fprintf(stderr, "%d failures\n", failures);
    return 1;
  }
  std::printf("chromium_host_input_ring_test: ok\n");
  return 0;
}
