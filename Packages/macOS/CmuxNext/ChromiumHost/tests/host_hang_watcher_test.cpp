// Checks the Chromium Host's hang watch (ChromiumHost/src/host_hang_watcher.h,
// scripts/cmux-next/tests/chromium-host-wire.test.sh):
// the wire, a turn's hang report and input ack, the watcher's decisions on a
// fake clock, the real watcher thread (no wakeup while idle, one dump per long
// turn) and cmux's ack count (InputAcks).
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

#include "../src/host_hang_watcher.h"

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

namespace {

using cmux_host::control::Message;
namespace hang = cmux_host::hang;

constexpr uint64_t kMs = 1'000'000;

// What the watch sent, from either thread.
struct Sent {
  std::mutex mutex;
  std::vector<Message> messages;

  hang::Watch::Send Sink() {
    return [this](const Message& message) {
      std::lock_guard<std::mutex> lock(mutex);
      messages.push_back(message);
      return true;
    };
  }
  std::vector<Message> Take() {
    std::lock_guard<std::mutex> lock(mutex);
    std::vector<Message> out;
    out.swap(messages);
    return out;
  }
};

// The fake clock of the single-threaded cases.
uint64_t fake_now = 1;
uint64_t FakeNow() {
  return fake_now;
}

uint64_t SteadyNow() {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()) + 1;
}

bool IsHang(const Message& message, hang::Hang expected) {
  hang::Hang got;
  return message.op == hang::kOpHostHang && hang::ReadHang(message, &got) && got == expected;
}

// cmux's rule (ChromiumHostHang.isFirstReport): an ongoing report, or an end the watcher did not report.
bool IsFirstReport(const Message& message) {
  hang::Hang got;
  if (message.op != hang::kOpHostHang || !hang::ReadHang(message, &got)) return false;
  return (got.flags & hang::kHangOngoing) != 0 || (got.flags & hang::kHangReported) == 0;
}

int FirstReports(const std::vector<Message>& messages) {
  int count = 0;
  for (const Message& message : messages) count += IsFirstReport(message) ? 1 : 0;
  return count;
}

cmux_host::Header Frame(uint32_t kind, uint32_t seq) {
  cmux_host::Header frame;
  frame.kind = kind;
  frame.seq = seq;
  return frame;
}

bool IsDispatched(const Message& message, uint32_t expected) {
  uint32_t seq = 0;
  return message.op == hang::kOpInputDispatched && hang::ReadDispatched(message, &seq) && seq == expected;
}

void TestWire() {
  hang::Hang read;
  Check(hang::ReadHang(hang::HangMessage({300 * kMs, hang::kHangOngoing | hang::kHangDumped}), &read) &&
            read == hang::Hang{300 * kMs, hang::kHangOngoing | hang::kHangDumped},
        "a hang report round-trips");
  uint32_t seq = 0;
  Check(hang::ReadDispatched(hang::DispatchedMessage(0xfffffffeu), &seq) && seq == 0xfffffffeu,
        "a dispatched seq round-trips with its bit pattern");
  Check(!hang::ReadDispatched(hang::DispatchedMessage(0), &seq), "seq 0 is malformed");
  Check(hang::ReadHang(hang::HangMessage({1, hang::kHangReported | hang::kHangDumped}), &read) &&
            read == hang::Hang{1, hang::kHangReported | hang::kHangDumped},
        "a reported end round-trips");
  Message bad_flags = hang::HangMessage({1, 8});
  Check(!hang::ReadHang(bad_flags, &read), "an unknown hang flag is malformed");
  Message extra = hang::DispatchedMessage(3);
  extra.fields.push_back(cmux_host::control::Field::I32(0, 1));
  Check(!hang::ReadDispatched(extra, &seq), "a field past the seq is malformed");
}

// A turn under 250 ms reports nothing, one of 250 ms or more reports its
// length once, at its end, on the UI thread.
void TestTurnReports() {
  Sent sent;
  hang::Watch watch(&FakeNow, sent.Sink(), nullptr);
  fake_now = 1000;
  watch.BeginTurn();
  fake_now += 249 * kMs;
  watch.EndTurn();
  Check(sent.Take().empty(), "a 249 ms turn is not a hang");
  watch.BeginTurn();
  fake_now += 300 * kMs;
  watch.BeginTurn();  // the next pass over the sources ends it
  std::vector<Message> got = sent.Take();
  Check(got.size() == 1 && IsHang(got[0], {300 * kMs, 0}), "a 300 ms turn reports 300 ms when it ends");
  watch.EndTurn();
  watch.EndTurn();
  Check(sent.Take().empty(), "a turn ends once");
}

// The input dispatched in a turn is acked once, at the turn's end, with the
// newest seq; outside a turn at once.
void TestDispatchAcks() {
  Sent sent;
  hang::Watch watch(&FakeNow, sent.Sink(), nullptr);
  fake_now = 5000;
  watch.BeginTurn();
  watch.InputDispatched(5);
  watch.InputDispatched(6);
  watch.InputDispatched(7);
  Check(sent.Take().empty(), "no ack before the turn ends");
  watch.EndTurn();
  std::vector<Message> got = sent.Take();
  Check(got.size() == 1 && IsDispatched(got[0], 7), "one ack of the newest seq per turn");
  watch.InputDispatched(8);
  got = sent.Take();
  Check(got.size() == 1 && IsDispatched(got[0], 8), "outside a turn the ack goes at once");
  watch.BeginTurn();
  watch.EndTurn();
  Check(sent.Take().empty(), "a turn that dispatched nothing acks nothing");
}

// A kPing's or kStats' seq is its request id: the turn acks the key's seq,
// whether the request id is below it or past the newest input written.
void TestRequestIdsAreNotAcked() {
  Sent sent;
  hang::Watch watch(&FakeNow, sent.Sink(), nullptr);
  fake_now = 6000;
  watch.BeginTurn();
  watch.FrameDispatched(Frame(cmux_host::kKey, 9));
  watch.FrameDispatched(Frame(cmux_host::kPing, 3));
  watch.EndTurn();
  std::vector<Message> got = sent.Take();
  Check(got.size() == 1 && IsDispatched(got[0], 9), "a ping after a key: the key's seq is acked, not the request id");
  watch.BeginTurn();
  watch.FrameDispatched(Frame(cmux_host::kKey, 10));
  watch.FrameDispatched(Frame(cmux_host::kStats, 500));
  watch.EndTurn();
  got = sent.Take();
  Check(got.size() == 1 && IsDispatched(got[0], 10), "a stats request id past the newest seq is not acked");
  watch.FrameDispatched(Frame(cmux_host::kPing, 11));
  Check(sent.Take().empty(), "a ping alone acks nothing");
  watch.BeginTurn();
  watch.InputDispatched(13);
  watch.InputDispatched(12);
  watch.EndTurn();
  got = sent.Take();
  Check(got.size() == 1 && IsDispatched(got[0], 13), "the turn acks the newest seq, not the last one");
}

// The watcher parks with no turn, sleeps until the open turn is 10 s old,
// dumps it once and parks again; the turn's end then says it was dumped.
void TestWatcherDecisions() {
  Sent sent;
  int dumps = 0;
  hang::Watch watch(&FakeNow, sent.Sink(), [&dumps] {
    ++dumps;
    return true;
  });
  fake_now = 10'000;
  Check(watch.Check(fake_now).kind == hang::Next::Kind::kPark, "no turn: park");
  watch.BeginTurn();
  const uint64_t begin = fake_now;
  hang::Next next = watch.Check(fake_now + 5);
  Check(next.kind == hang::Next::Kind::kSleep && next.until_ns == begin + 10'000 * kMs,
        "an open turn: sleep until it is 10 s old");
  next = watch.Check(begin + 10'000 * kMs);
  Check(next.kind == hang::Next::Kind::kDump, "a 10 s turn: dump");
  watch.DumpTurn(next.turn, begin + 10'000 * kMs);
  std::vector<Message> got = sent.Take();
  Check(dumps == 1 && got.size() == 1 && IsHang(got[0], {10'000 * kMs, hang::kHangOngoing | hang::kHangDumped}),
        "the dump is reported as an ongoing hang");
  Check(watch.Check(begin + 20'000 * kMs).kind == hang::Next::Kind::kPark, "a dumped turn: park until the next");
  watch.DumpTurn(next.turn, begin + 20'000 * kMs);
  Check(dumps == 1, "a turn is dumped once");
  fake_now = begin + 12'000 * kMs;
  watch.EndTurn();
  got = sent.Take();
  Check(got.size() == 1 && IsHang(got[0], {12'000 * kMs, hang::kHangDumped | hang::kHangReported}) &&
            !IsFirstReport(got[0]),
        "its end reports 12 s, dumped, already reported");
  watch.BeginTurn();
  Check(watch.Check(fake_now).kind == hang::Next::Kind::kSleep, "the next turn is watched");
  watch.DumpTurn(next.turn, fake_now + 10'000 * kMs);
  Check(dumps == 1, "a stale turn is never dumped");
}

// A turn that ends after its dump deadline but before the late watcher looks:
// its end claims it, the watcher then dumps nothing, and cmux takes one report.
void TestTurnEndsBeforeTheLateWatcher() {
  Sent sent;
  int dumps = 0;
  hang::Watch watch(&FakeNow, sent.Sink(), [&dumps] {
    ++dumps;
    return true;
  });
  fake_now = 80'000;
  watch.BeginTurn();
  const uint64_t begin = fake_now;
  const hang::Next next = watch.Check(begin + 10'000 * kMs);
  Check(next.kind == hang::Next::Kind::kDump, "the watcher decided to dump");
  fake_now = begin + 10'000 * kMs + 1;
  watch.EndTurn();
  watch.DumpTurn(next.turn, fake_now + 5 * kMs);
  std::vector<Message> got = sent.Take();
  Check(dumps == 0, "a turn its end reported is not dumped");
  Check(got.size() == 1 && IsHang(got[0], {10'000 * kMs + 1, 0}) && FirstReports(got) == 1,
        "one first report of a 10 s hang the watcher missed");
  // The other order: the watcher's ongoing report first, then the end says it was reported.
  watch.BeginTurn();
  const uint64_t second = fake_now;
  watch.DumpTurn(watch.Check(second + 10'000 * kMs).turn, second + 10'000 * kMs);
  fake_now = second + 11'000 * kMs;
  watch.EndTurn();
  got = sent.Take();
  Check(got.size() == 2 && IsHang(got[1], {11'000 * kMs, hang::kHangDumped | hang::kHangReported}) &&
            FirstReports(got) == 1,
        "dumped then ended: one first report, the end marked reported");
}

// No watcher thread (Start failed or never ran): turns still report, and a
// 12 s hang is one first report.
void TestNoWatcherThread() {
  Sent sent;
  hang::Watch watch(&FakeNow, sent.Sink(), [] { return true; });
  fake_now = 90'000;
  watch.BeginTurn();
  fake_now += 12'000 * kMs;
  watch.EndTurn();
  std::vector<Message> got = sent.Take();
  Check(got.size() == 1 && IsHang(got[0], {12'000 * kMs, 0}) && FirstReports(got) == 1,
        "with no watcher a long hang is reported once, as first");
}

// A dump that writes nothing still reports the hang, with no dumped flag.
void TestDumpRefused() {
  Sent sent;
  hang::Watch watch(&FakeNow, sent.Sink(), [] { return false; });
  fake_now = 70'000;
  watch.BeginTurn();
  const hang::Next next = watch.Check(fake_now + 10'000 * kMs);
  watch.DumpTurn(next.turn, fake_now + 10'000 * kMs);
  std::vector<Message> got = sent.Take();
  Check(got.size() == 1 && IsHang(got[0], {10'000 * kMs, hang::kHangOngoing}), "a refused dump is reported as not dumped");
}

// The real thread: no wakeup while no turn is open, one dump per long turn,
// none for short ones, and Stop ends a parked watcher at once.
void TestWatcherThread() {
  Sent sent;
  std::atomic<int> dumps{0};
  hang::Limits limits;
  limits.report_ns = 20 * kMs;
  limits.dump_ns = 100 * kMs;
  hang::Watch watch(&SteadyNow, sent.Sink(), [&dumps] {
    ++dumps;
    return true;
  }, limits);
  watch.Start();
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  Check(watch.parked() && watch.wakes() == 0, "an idle host's watcher parks with no wakeup");
  const auto burst_started = std::chrono::steady_clock::now();
  for (int i = 0; i < 2000; ++i) {
    watch.BeginTurn();
    watch.EndTurn();
  }
  const auto burst = std::chrono::steady_clock::now() - burst_started;
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  Check(dumps.load() == 0, "short turns are never dumped");
  // One wake out of the park, then at most one per dump period of turns (Chrome's watcher: one per
  // kHangWatcherMonitoringPeriod), and the last sleep's end.
  const auto periods = static_cast<uint64_t>(burst / std::chrono::milliseconds(100));
  Check(watch.wakes() <= 2 + periods, "a burst of short turns wakes the watcher once per dump period at most");
  watch.BeginTurn();
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  Check(dumps.load() == 1, "a turn past the dump deadline is dumped once");
  watch.EndTurn();
  std::vector<Message> got = sent.Take();
  bool ongoing = false, ended = false;
  for (const Message& message : got) {
    hang::Hang h;
    if (message.op != hang::kOpHostHang || !hang::ReadHang(message, &h)) continue;
    if (h.flags == (hang::kHangOngoing | hang::kHangDumped) && h.duration_ns >= 100 * kMs) ongoing = true;
    if (h.flags == (hang::kHangDumped | hang::kHangReported) && h.duration_ns >= 400 * kMs) ended = true;
  }
  Check(ongoing && ended && FirstReports(got) == 1, "the long turn is reported at its dump and at its end, first once");
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  const uint64_t wakes = watch.wakes();
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  Check(watch.parked() && watch.wakes() == wakes, "idle again: parked, no wakeup");
  const auto stop_started = std::chrono::steady_clock::now();
  watch.Stop();
  Check(std::chrono::steady_clock::now() - stop_started < std::chrono::milliseconds(100), "Stop ends a parked watcher at once");
}

void TestInputAcks() {
  using Change = hang::InputAcks::Change;
  hang::InputAcks acks;
  Check(acks.Dispatched(1) == Change::kNone, "an ack with nothing written changes nothing");
  Check(acks.Written(1) == Change::kOutstanding, "the first written seq waits");
  Check(acks.Written(2) == Change::kNone && acks.waiting(), "later seqs join the wait");
  Check(acks.Dispatched(1) == Change::kProgress, "the host dispatched seq 1, seq 2 still waits");
  Check(acks.Dispatched(2) == Change::kSettled && !acks.waiting(), "seq 2 dispatched: nothing waits");
  Check(acks.Dispatched(2) == Change::kNone, "a repeated ack changes nothing");
  Check(acks.Written(0xffffffffu) == Change::kOutstanding, "a seq at the wrap waits");
  Check(acks.Written(1) == Change::kNone, "the seq after the wrap");
  Check(acks.Dispatched(0xffffffffu) == Change::kProgress, "the ack before the wrap leaves the one after");
  Check(acks.Dispatched(1) == Change::kSettled, "the ack after the wrap settles it");
  Check(acks.Written(3) == Change::kOutstanding && acks.Reset() == Change::kSettled && !acks.waiting(),
        "a host that ends settles what waited");
  Check(acks.Reset() == Change::kNone, "a second reset changes nothing");

  // Control-channel input: tokens acked by the host's kOpAck; an ack of any token at or after a
  // waiting one says it ran, an ack before the oldest waiting one says nothing.
  Check(acks.ControlWritten(10) == Change::kOutstanding, "a control input op waits");
  Check(acks.ControlAcked(9) == Change::kNone, "an op posted before it ran: no news of the input");
  Check(acks.ControlWritten(12) == Change::kNone, "a second joins the wait");
  Check(acks.ControlAcked(11) == Change::kProgress, "an op between them ran: the first did");
  Check(acks.ControlAcked(11) == Change::kNone, "a repeated ack changes nothing");
  Check(acks.ControlAcked(13) == Change::kSettled && !acks.waiting(), "an op after the newest ran: all did");
  // Both streams wait together.
  Check(acks.Written(5) == Change::kOutstanding, "ring input waits");
  Check(acks.ControlWritten(20) == Change::kNone, "control input joins the wait");
  Check(acks.Dispatched(5) == Change::kProgress && acks.waiting(), "the ring is done, the control op waits");
  Check(acks.ControlAcked(20) == Change::kSettled && !acks.waiting(), "both done");
  Check(acks.ControlWritten(21) == Change::kOutstanding && acks.Reset() == Change::kSettled && !acks.waiting(),
        "a host that ends settles control input too");
}

}  // namespace

int main() {
  TestWire();
  TestTurnReports();
  TestDispatchAcks();
  TestRequestIdsAreNotAcked();
  TestWatcherDecisions();
  TestTurnEndsBeforeTheLateWatcher();
  TestNoWatcherThread();
  TestDumpRefused();
  TestWatcherThread();
  TestInputAcks();
  if (failures != 0) {
    std::fprintf(stderr, "host_hang_watcher_test: %d failures\n", failures);
    return 1;
  }
  std::printf("host_hang_watcher_test: ok\n");
  return 0;
}
