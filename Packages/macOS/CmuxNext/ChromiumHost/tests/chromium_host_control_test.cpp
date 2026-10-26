// Checks the control channel (ChromiumHost/src/chromium_host_control.h): the
// golden frame that ChromiumHostControlChannelTests.swift checks too, the
// malformed-frame rules, the outbox's coalescing and quota, and a channel on
// a real socket pair (scripts/cmux-next/tests/chromium-host-wire.test.sh).
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "../src/chromium_host_control.h"

namespace control = cmux_host::control;

static const char kGolden[] =
    "2d00000003020800efbeadde01010400feffffff020208000807060504030201"
    "03030800000000000000f83f0404020000ff0505030068c3a9";

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

static std::vector<uint8_t> Hex(const char* hex) {
  std::vector<uint8_t> bytes;
  for (size_t i = 0; hex[i] != 0 && hex[i + 1] != 0; i += 2) {
    unsigned value = 0;
    std::sscanf(hex + i, "%2x", &value);
    bytes.push_back(static_cast<uint8_t>(value));
  }
  return bytes;
}

static control::Message GoldenMessage() {
  control::Message m;
  m.op = 0x0203;
  m.reply = true;
  m.token = 0xdeadbeef;
  m.fields = {control::Field::I32(1, -2), control::Field::I64(2, 0x0102030405060708LL), control::Field::F64(3, 1.5),
              control::Field::Bytes(4, std::string("\x00\xff", 2)), control::Field::Str(5, "h\xc3\xa9")};
  return m;
}

static control::Parse DecodeAll(const std::vector<uint8_t>& bytes, std::deque<int>* fds, control::Message* out) {
  size_t consumed = 0;
  return control::Decode(bytes.data(), bytes.size(), fds, out, &consumed);
}

// The UI thread of a test: tasks the channel posts, run by Pump on the test's thread.
struct Ui {
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<std::function<void()>> tasks;
  std::vector<control::Message> messages;
  std::vector<control::End> ends;
  int batches = 0;

  control::Channel::Post Poster() {
    return [this](std::function<void()> task) {
      std::lock_guard<std::mutex> lock(mutex);
      tasks.push_back(std::move(task));
      changed.notify_all();
    };
  }
  control::Channel::OnMessages Receiver() {
    return [this](std::vector<control::Message> batch) {
      ++batches;
      for (auto& m : batch) messages.push_back(std::move(m));
    };
  }
  control::Channel::OnEnd Ender() {
    return [this](control::End end) { ends.push_back(end); };
  }
  // Runs posted tasks until `done` or two seconds pass.
  bool Pump(const std::function<bool()>& done) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex);
        while (tasks.empty()) {
          lock.unlock();
          if (done()) return true;
          lock.lock();
          if (changed.wait_until(lock, deadline) == std::cv_status::timeout && tasks.empty()) return done();
        }
        task = std::move(tasks.front());
        tasks.pop_front();
      }
      task();
    }
  }
};

static void SocketPair(int fds[2]) {
  if (::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
    std::perror("socketpair");
    std::exit(2);
  }
}

static control::Message Geometry(int32_t browser, int32_t width) {
  control::Message m;
  m.op = 2;
  m.fields = {control::Field::I32(1, browser), control::Field::I32(2, width)};
  return m;
}

static control::Message Key(int32_t browser, int32_t code) {
  control::Message m;
  m.op = 5;
  m.fields = {control::Field::I32(1, browser), control::Field::I32(2, code)};
  return m;
}

static void TestGolden() {
  const std::vector<uint8_t> golden = Hex(kGolden);
  std::vector<uint8_t> encoded;
  Check(control::Encode(GoldenMessage(), &encoded), "the golden message encodes");
  Check(encoded == golden, "encode matches the golden frame");
  std::deque<int> fds;
  control::Message decoded;
  Check(DecodeAll(golden, &fds, &decoded) == control::Parse::kFrame, "the golden frame decodes");
  const control::Message want = GoldenMessage();
  Check(decoded.op == want.op && decoded.reply && decoded.token == want.token && decoded.fields == want.fields,
        "the golden frame decodes to the golden message");
  Check(decoded.Find(5) != nullptr && decoded.Find(5)->bytes == "h\xc3\xa9" && decoded.Find(9) == nullptr, "find by tag");
  std::vector<uint8_t> partial(golden.begin(), golden.end() - 1);
  Check(DecodeAll(partial, &fds, &decoded) == control::Parse::kNeedMore, "a frame cut short waits for more");
}

static void TestMalformed() {
  std::deque<int> fds;
  control::Message out;
  std::vector<uint8_t> header = Hex(kGolden);
  header.resize(control::kHeaderSize);
  const uint32_t too_long = control::kMaxBody + 1;
  std::memcpy(header.data(), &too_long, 4);  // little-endian hosts only (macOS, Linux CI)
  Check(DecodeAll(header, &fds, &out) == control::Parse::kMalformed, "a length over the limit is malformed at once");

  auto with = [](size_t offset, uint8_t value) {
    std::vector<uint8_t> bytes = Hex(kGolden);
    bytes[offset] = value;
    return bytes;
  };
  Check(DecodeAll(with(7, 0x01), &fds, &out) == control::Parse::kMalformed, "an unknown flag is malformed");
  Check(DecodeAll(with(6, 0x0d), &fds, &out) == control::Parse::kMalformed, "more than four descriptors is malformed");
  Check(DecodeAll(with(6, 0x09), &fds, &out) == control::Parse::kMalformed, "a descriptor that did not arrive is malformed");
  Check(DecodeAll(with(12, 9), &fds, &out) == control::Parse::kMalformed, "an unknown type is malformed");
  Check(DecodeAll(with(14, 3), &fds, &out) == control::Parse::kMalformed, "an i32 of three bytes is malformed");
  Check(DecodeAll(with(52, 0x30), &fds, &out) == control::Parse::kMalformed, "a field past the body is malformed");
  Check(DecodeAll(with(55, 0xff), &fds, &out) == control::Parse::kMalformed, "bad UTF-8 in a str is malformed");

  control::Message bad;
  bad.fields = {control::Field::Str(1, "\xc3")};
  std::vector<uint8_t> encoded;
  Check(!control::Encode(bad, &encoded) && encoded.empty(), "bad UTF-8 is never sent");
  control::Message big;
  big.fields = {control::Field::Bytes(1, std::string(60000, 'a')), control::Field::Bytes(2, std::string(6000, 'b'))};
  Check(!control::Encode(big, &encoded), "a body over 64 KiB is never sent");
}

static void TestOutbox() {
  control::Outbox outbox(1 << 20, 8);
  auto bytes = [](uint8_t mark) { return std::vector<uint8_t>(16, mark); };
  const uint64_t page1 = control::StateKey(2, 1), page2 = control::StateKey(2, 2);
  for (int i = 0; i < 1000; ++i) {
    outbox.Push(bytes(1), {}, page1);
    outbox.Push(bytes(2), {}, page2);
    if (i % 100 == 0) outbox.Push(bytes(static_cast<uint8_t>(100 + i / 100)), {}, std::nullopt);
  }
  Check(outbox.CountKey(page1) == 1 && outbox.CountKey(page2) == 1, "a thousand geometries per page wait as one each");
  Check(outbox.messages() == 12, "keys are each kept");
  Check(outbox.OverQuota(), "twelve waiting messages are over a quota of eight");
  std::vector<uint8_t> order;
  while (control::Outbox::Entry* front = outbox.Front()) {
    order.push_back(front->bytes[0]);
    outbox.PopFront();
  }
  const std::vector<uint8_t> want = {100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 1, 2};
  Check(order == want, "keys keep their order; the newest geometry goes after them");
  Check(outbox.empty() && outbox.bytes() == 0, "an emptied outbox holds nothing");

  outbox.Push(bytes(1), {}, page1);
  outbox.Front()->offset = 4;  // partly written
  Check(!outbox.Push(bytes(3), {}, page1), "a partly written state op is never replaced");
  Check(outbox.messages() == 2, "the newer one waits behind it");
}

static void TestRoundTripWithDescriptors() {
  int pair[2];
  SocketPair(pair);
  Ui ui_a, ui_b;
  control::Channel a(pair[0], ui_a.Poster(), ui_a.Receiver(), ui_a.Ender());
  control::Channel b(pair[1], ui_b.Poster(), ui_b.Receiver(), ui_b.Ender());
  int pipe_fds[2];
  Check(::pipe(pipe_fds) == 0, "pipe");
  control::Message m = GoldenMessage();
  m.reply = false;
  m.fds = {pipe_fds[1]};
  Check(a.Send(m), "a frame with a descriptor is sent");
  ::close(pipe_fds[1]);  // the channel sent its own duplicate
  for (int i = 0; i < 100; ++i) Check(a.Send(Key(1, i)), "keys are sent");
  Check(ui_b.Pump([&] { return ui_b.messages.size() == 101; }), "every frame arrives");
  if (ui_b.messages.size() == 101) {
    control::Message& got = ui_b.messages[0];
    Check(got.fields == GoldenMessage().fields && got.fds.size() == 1, "the frame and its descriptor arrive together");
    if (got.fds.size() == 1) {
      Check(::write(got.fds[0], "x", 1) == 1, "the descriptor received writes to the pipe");
      ::close(got.fds[0]);
      char byte = 0;
      Check(::read(pipe_fds[0], &byte, 1) == 1 && byte == 'x', "the byte comes out of the pipe");
    }
    bool ordered = true;
    for (int i = 0; i < 100; ++i) ordered = ordered && ui_b.messages[1 + i].Find(2)->integer == i;
    Check(ordered, "keys arrive in order");
    Check(ui_b.batches < 101, "frames reach the UI thread in batches, not one task each");
  }
  ::close(pipe_fds[0]);
  a.Close();
  Check(ui_b.Pump([&] { return !ui_b.ends.empty(); }) && ui_b.ends[0] == control::End::kPeerClosed,
        "the peer's close ends the channel");
  Check(!b.Send(Key(1, 1)), "an ended channel sends nothing");
}

static void TestBadLengthEnds() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  std::vector<uint8_t> good;
  control::Encode(Key(1, 7), &good);
  std::vector<uint8_t> header(control::kHeaderSize, 0);
  const uint32_t too_long = control::kMaxBody + 1;
  std::memcpy(header.data(), &too_long, 4);
  good.insert(good.end(), header.begin(), header.end());
  Check(::write(pair[1], good.data(), good.size()) == static_cast<ssize_t>(good.size()), "raw write");
  Check(ui.Pump([&] { return !ui.ends.empty(); }), "a bad length ends the connection");
  Check(ui.ends.size() == 1 && ui.ends[0] == control::End::kMalformed, "as malformed");
  Check(ui.messages.size() == 1, "the good frame before it is delivered first");
  char byte;
  Check(::read(pair[1], &byte, 1) == 0, "the peer reads EOF");
  ::close(pair[1]);
}

static void TestNeverReadingPeer() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  const auto start = std::chrono::steady_clock::now();
  bool all = true;
  for (int i = 0; i < 20000; ++i) {
    all = channel.Send(Geometry(1, i), control::StateKey(2, 1)) && all;
    all = channel.Send(Geometry(2, i), control::StateKey(2, 2)) && all;
    if (i % 2 == 0) all = channel.Send(Key(1, i)) && all;
  }
  const auto took = std::chrono::steady_clock::now() - start;
  Check(all, "every send is taken while the peer never reads");
  Check(took < std::chrono::seconds(2), "sends never block on a peer that does not read");
  const control::Stats stats = channel.stats();
  Check(channel.PendingWithKey(control::StateKey(2, 1)) <= 1 && channel.PendingWithKey(control::StateKey(2, 2)) <= 1,
        "geometry waits as at most one per page");
  Check(stats.coalesced > 0, "waiting geometries were replaced");
  Check(stats.quota_excess > 0, "the excess over quota is counted");
  Check(ui.ends.empty(), "over quota does not end the channel");
  ::close(pair[1]);
}

static void TestQuotaCeiling() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel::Options options;
  options.quota_messages = 4;
  options.quota_ceiling = std::chrono::milliseconds(50);
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender(), options);
  control::Message big;
  big.op = 9;
  big.fields = {control::Field::Bytes(1, std::string(60000, 'z'))};
  for (int i = 0; i < 64; ++i) channel.Send(big);
  Check(channel.stats().quota_excess > 0, "the outbox is over quota");
  Check(ui.Pump([&] { return !ui.ends.empty(); }), "the ceiling ends a channel over quota the whole time");
  Check(ui.ends.size() == 1 && ui.ends[0] == control::End::kQuotaCeiling, "as the quota ceiling");
  ::close(pair[1]);
}

static void TestInboxBackPressure() {
  int pair[2];
  SocketPair(pair);
  Ui ui_a, ui_b;
  control::Channel a(pair[0], ui_a.Poster(), ui_a.Receiver(), ui_a.Ender());
  control::Channel::Options options;
  options.inbox_limit = 4;
  control::Channel b(pair[1], ui_b.Poster(), ui_b.Receiver(), ui_b.Ender(), options);
  for (int i = 0; i < 5000; ++i) a.Send(Key(1, i));
  Check(ui_b.Pump([&] { return ui_b.messages.size() == 5000; }), "a paused reader reads again after each drain");
  bool ordered = ui_b.messages.size() == 5000;
  for (size_t i = 0; ordered && i < ui_b.messages.size(); ++i) {
    ordered = ui_b.messages[i].Find(2)->integer == static_cast<int64_t>(i);
  }
  Check(ordered, "and keeps the order");
}

int main() {
  TestGolden();
  TestMalformed();
  TestOutbox();
  TestRoundTripWithDescriptors();
  TestBadLengthEnds();
  TestNeverReadingPeer();
  TestQuotaCeiling();
  TestInboxBackPressure();
  if (failures) return 1;
  std::printf("chromium_host_control_test: ok\n");
  return 0;
}
