// Checks the control channel (ChromiumHost/src/chromium_host_control.h): the
// golden frame that ChromiumHostControlChannelTests.swift checks too, the
// malformed-frame rules, the outbox's coalescing and quota, and a channel on
// a real socket pair (scripts/cmux-next/tests/chromium-host-wire.test.sh).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
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
  size_t largest_batch_bytes = 0;  // the most payload bytes one drain delivered

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
      size_t bytes = 0;
      for (const auto& m : batch) {
        for (const auto& field : m.fields) bytes += field.bytes.size();
      }
      largest_batch_bytes = std::max(largest_batch_bytes, bytes);
      for (auto& m : batch) messages.push_back(std::move(m));
    };
  }
  control::Channel::OnEnd Ender() {
    return [this](control::End end) { ends.push_back(end); };
  }
  // Runs the tasks posted so far.
  void RunQueued() {
    std::deque<std::function<void()>> queued;
    {
      std::lock_guard<std::mutex> lock(mutex);
      queued.swap(tasks);
    }
    for (auto& task : queued) task();
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
  Check(outbox.CountKey(page1) == 1, "the partly written one is in flight, not waiting");
  Check(outbox.Push(bytes(4), {}, page1), "a newer one replaces the waiting one");
  Check(outbox.CountKey(page1) == 1 && outbox.messages() == 2, "one in flight and one waiting per page");
}

// One sendmsg per batch: small frames go together; a frame with descriptors
// starts a batch, since they go with its first byte.
static void TestOutboxBatches() {
  control::Outbox outbox(1 << 20, 4096);
  int pipe_fds[2];
  Check(::pipe(pipe_fds) == 0 && ::fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) == 0, "pipe; its reads never wait");
  for (int i = 0; i < 3; ++i) outbox.Push(std::vector<uint8_t>(16, 1), {}, std::nullopt);
  outbox.Push(std::vector<uint8_t>(16, 2), {::dup(pipe_fds[1])}, std::nullopt);
  for (int i = 0; i < 100; ++i) outbox.Push(std::vector<uint8_t>(16, 3), {}, std::nullopt);
  iovec iov[control::kMaxBatch];
  const std::vector<int>* fds = nullptr;
  size_t count = outbox.Gather(iov, control::kMaxBatch, &fds);
  Check(count == 3 && fds == nullptr, "frames before the one with a descriptor go as one batch");
  outbox.Advance(3 * 16);
  count = outbox.Gather(iov, control::kMaxBatch, &fds);
  Check(count == control::kMaxBatch && fds != nullptr && fds->size() == 1, "the descriptor leads the next batch");
  outbox.Advance(16 + 8);  // the socket took the frame with the descriptor and half the next
  count = outbox.Gather(iov, control::kMaxBatch, &fds);
  Check(fds == nullptr && iov[0].iov_len == 8, "the next batch starts where the socket stopped");
  Check(outbox.messages() == 100, "frames written whole left");
  outbox.Clear();
  // The duplicate is closed: the pipe's write end is the original alone.
  ::close(pipe_fds[1]);
  char byte;
  Check(::read(pipe_fds[0], &byte, 1) == 0, "the sent descriptor was closed once it went");
  ::close(pipe_fds[0]);
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
  Check(channel.PendingWithKey(control::StateKey(2, 1)) == 1 && channel.PendingWithKey(control::StateKey(2, 2)) == 1,
        "geometry waits as one per page");
  Check(stats.coalesced > 0, "waiting geometries were replaced");
  Check(stats.quota_excess > 0, "the excess over quota is counted");
  Check(ui.ends.empty(), "over quota does not end the channel");

  // The peer reads at last: every key arrives, in order, and the newest
  // geometry of each page comes after them.
  Ui peer_ui;
  control::Channel peer(pair[1], peer_ui.Poster(), peer_ui.Receiver(), peer_ui.Ender());
  auto last_two_are_newest = [&] {
    const auto& got = peer_ui.messages;
    return got.size() >= 2 && got[got.size() - 2].op == 2 && got[got.size() - 2].Find(2)->integer == 19999 &&
           got.back().op == 2 && got.back().Find(2)->integer == 19999;
  };
  Check(peer_ui.Pump(last_two_are_newest), "the newest geometries arrive last");
  std::vector<int64_t> keys;
  int64_t last_width[3] = {-1, -1, -1};
  for (const control::Message& m : peer_ui.messages) {
    if (m.op == 5) keys.push_back(m.Find(2)->integer);
    if (m.op == 2) last_width[m.Find(1)->integer] = m.Find(2)->integer;
  }
  bool ordered = keys.size() == 10000;
  for (size_t i = 0; ordered && i < keys.size(); ++i) ordered = keys[i] == static_cast<int64_t>(2 * i);
  Check(ordered, "every key arrives, in order");
  Check(last_width[1] == 19999 && last_width[2] == 19999, "the newest geometry of each page is the last one");
  Check(ui.ends.empty() && peer_ui.ends.empty(), "nothing ended");
}

// The peer closes while frames wait in the outbox: the end says the peer
// closed, not that the socket broke.
static void TestPeerClosesWithOutboxWaiting() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  for (int i = 0; i < 1000000 && channel.stats().pending_messages == 0; ++i) channel.Send(Key(1, i));
  Check(channel.stats().pending_messages > 0, "frames wait in the outbox");
  ::close(pair[1]);
  Check(ui.Pump([&] { return !ui.ends.empty(); }), "the peer's close ends the channel");
  Check(ui.ends.size() == 1 && ui.ends[0] == control::End::kPeerClosed, "as peer closed");
  Check(!channel.Send(Key(1, 1)), "nothing is sent after it");
}

// Writes `bytes` on `fd` with `fd_to_pass` attached to their first byte.
static bool SendWithDescriptor(int fd, const std::vector<uint8_t>& bytes, int fd_to_pass) {
  iovec iov;
  iov.iov_base = const_cast<uint8_t*>(bytes.data());
  iov.iov_len = bytes.size();
  alignas(cmsghdr) uint8_t control_bytes[CMSG_SPACE(sizeof(int))];
  std::memset(control_bytes, 0, sizeof control_bytes);
  msghdr header;
  std::memset(&header, 0, sizeof header);
  header.msg_iov = &iov;
  header.msg_iovlen = 1;
  header.msg_control = control_bytes;
  header.msg_controllen = sizeof control_bytes;
  cmsghdr* message = CMSG_FIRSTHDR(&header);
  message->cmsg_level = SOL_SOCKET;
  message->cmsg_type = SCM_RIGHTS;
  message->cmsg_len = CMSG_LEN(sizeof(int));
  std::memcpy(CMSG_DATA(message), &fd_to_pass, sizeof(int));
  return ::sendmsg(fd, &header, 0) == static_cast<ssize_t>(bytes.size());
}

// A descriptor on a frame that declares none is malformed, not given to a later frame.
static void TestUndeclaredDescriptorIsMalformed() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  int pipe_fds[2];
  Check(::pipe(pipe_fds) == 0 && ::fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) == 0, "pipe; its reads never wait");
  std::vector<uint8_t> frame;
  control::Encode(Key(1, 7), &frame);
  Check(SendWithDescriptor(pair[1], frame, pipe_fds[1]), "raw sendmsg");
  ::close(pipe_fds[1]);
  Check(ui.Pump([&] { return !ui.ends.empty(); }), "an undeclared descriptor ends the connection");
  Check(ui.ends.size() == 1 && ui.ends[0] == control::End::kMalformed, "as malformed");
  char byte;
  Check(::read(pipe_fds[0], &byte, 1) == 0, "the stray descriptor is closed");
  ::close(pipe_fds[0]);
  ::close(pair[1]);
}

// Coalescing brings the outbox back under quota while the peer reads nothing:
// the ceiling, which counts only time over quota without a break, ends nothing.
static void TestCeilingSparesAnOutboxBackUnderQuota() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel::Options options;
  options.quota_bytes = 32 * 1024;
  options.quota_ceiling = std::chrono::milliseconds(50);
  control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender(), options);
  for (int i = 0; i < 1000000 && channel.stats().pending_messages == 0; ++i) channel.Send(Key(1, i));
  control::Message big = Geometry(1, 1);
  big.fields.push_back(control::Field::Bytes(3, std::string(60000, 's')));
  channel.Send(big, control::StateKey(2, 1));
  Check(channel.stats().quota_excess > 0, "a large waiting state op is over quota");
  channel.Send(Geometry(1, 2), control::StateKey(2, 1));
  Check(channel.stats().pending_bytes < options.quota_bytes, "its replacement is under quota");
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  Check(channel.Send(Key(1, 1)), "past the ceiling the channel still sends");
  ui.RunQueued();
  Check(ui.ends.empty(), "nothing ended");
  ::close(pair[1]);
}

// After ~Channel no callback runs, even from a drain posted before it.
static void TestDestroyStopsDelivery() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  {
    control::Channel channel(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
    std::vector<uint8_t> frame;
    control::Encode(Key(1, 7), &frame);
    Check(::write(pair[1], frame.data(), frame.size()) == static_cast<ssize_t>(frame.size()), "raw write");
    std::unique_lock<std::mutex> lock(ui.mutex);
    Check(ui.changed.wait_for(lock, std::chrono::seconds(2), [&] { return !ui.tasks.empty(); }), "a drain is posted");
  }
  ui.RunQueued();
  Check(ui.messages.empty() && ui.ends.empty(), "a drain posted before ~Channel delivers nothing after it");
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

// Task 020: a 10 MB payload, a PNG of 70 KB beside it, as a page resource
// body goes: round-trips through two channels, and the socket carries only a
// small frame and the regions.
static std::string Pattern(size_t size, uint8_t seed) {
  std::string bytes(size, '\0');
  for (size_t i = 0; i < size; ++i) bytes[i] = static_cast<char>((i * 31 + seed) & 0xff);
  return bytes;
}

static control::Message LargeResource() {
  control::Message m;
  m.op = 0x0301;
  m.fields = {control::Field::I32(1, 42), control::Field::Str(2, "text/html; charset=utf-8"),
              control::Field::Bytes(3, Pattern(10 * 1024 * 1024, 7)), control::Field::Bytes(4, Pattern(70000, 3)),
              control::Field::Str(5, std::string(200000, 'a'))};
  return m;
}

static void TestSharedFieldsChoice() {
  const control::Message large = LargeResource();
  Check(control::SharedFields(large) == std::vector<size_t>{2, 3, 4}, "every field over 65,535 bytes goes shared");
  control::Message two;
  two.fields = {control::Field::Bytes(1, std::string(40000, 'x')), control::Field::Bytes(2, std::string(30000, 'y')),
                control::Field::Bytes(3, std::string(20000, 'z'))};
  Check(control::SharedFields(two) == std::vector<size_t>{0}, "then the largest until the body fits");
  Check(control::SharedFields(GoldenMessage()).empty(), "a frame that fits shares nothing");
  control::Message too_many = large;
  too_many.fields.push_back(control::Field::Bytes(6, std::string(70000, 'b')));
  too_many.fields.push_back(control::Field::Bytes(7, std::string(70000, 'c')));
  std::vector<uint8_t> out;
  Check(!control::EncodeShared(too_many, control::SharedFields(too_many), &out), "more regions than descriptors is never sent");
}

static void TestLargePayloadRoundTrips() {
  int pair[2];
  SocketPair(pair);
  Ui ui_a, ui_b;
  control::Channel a(pair[0], ui_a.Poster(), ui_a.Receiver(), ui_a.Ender());
  control::Channel b(pair[1], ui_b.Poster(), ui_b.Receiver(), ui_b.Ender());
  int pipe_fds[2];
  Check(::pipe(pipe_fds) == 0, "pipe");
  control::Message sent = LargeResource();
  sent.fds = {pipe_fds[1]};
  Check(a.Send(sent), "a 10 MB resource is sent");
  ::close(pipe_fds[1]);
  Check(a.Send(Key(1, 1)), "a key after it");
  Check(ui_b.Pump([&] { return ui_b.messages.size() == 2; }), "both arrive");
  if (ui_b.messages.size() == 2) {
    control::Message& got = ui_b.messages[0];
    Check(got.fields == LargeResource().fields, "the 10 MB resource round-trips byte for byte");
    Check(got.fds.size() == 1, "the caller's descriptor arrives; the regions are read and closed");
    for (int fd : got.fds) ::close(fd);
    Check(ui_b.messages[1].op == 5, "the key follows it");
  }
  ::close(pipe_fds[0]);
}

// Reads what the peer wrote: the socket bytes and the descriptors.
static void ReadRaw(int fd, std::vector<uint8_t>* bytes, std::deque<int>* fds) {
  for (;;) {
    uint8_t chunk[256 * 1024];
    iovec iov{chunk, sizeof chunk};
    alignas(cmsghdr) uint8_t control_bytes[CMSG_SPACE(sizeof(int) * 16)];
    msghdr header;
    std::memset(&header, 0, sizeof header);
    header.msg_iov = &iov;
    header.msg_iovlen = 1;
    header.msg_control = control_bytes;
    header.msg_controllen = sizeof control_bytes;
    const ssize_t count = ::recvmsg(fd, &header, MSG_DONTWAIT);
    if (count <= 0) return;
    for (cmsghdr* c = CMSG_FIRSTHDR(&header); c != nullptr; c = CMSG_NXTHDR(&header, c)) {
      const size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      for (size_t i = 0; i < n; ++i) {
        int got;
        std::memcpy(&got, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
        fds->push_back(got);
      }
    }
    bytes->insert(bytes->end(), chunk, chunk + count);
  }
}

static void TestNoSocketFrameOver64KiB() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel a(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  Check(a.Send(LargeResource()), "sent");
  std::vector<uint8_t> raw;
  std::deque<int> fds;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (raw.size() < control::kHeaderSize && std::chrono::steady_clock::now() < deadline) ReadRaw(pair[1], &raw, &fds);
  Check(raw.size() <= control::kHeaderSize + control::kMaxBody, "the socket carries no message over 64 KiB");
  Check(fds.size() == 3, "one region per large field");
  for (int fd : fds) {
    char probe = 0;
    Check(::write(fd, &probe, 1) < 0, "a region is not writable by the receiver");
#if defined(__linux__)
    const int seals = ::fcntl(fd, F_GET_SEALS);
    Check(seals >= 0 && (seals & F_SEAL_WRITE) && (seals & F_SEAL_SHRINK) && (seals & F_SEAL_SEAL), "a region is sealed");
#endif
  }
  control::Message decoded;
  size_t consumed = 0;
  Check(control::Decode(raw.data(), raw.size(), &fds, &decoded, &consumed) == control::Parse::kFrame &&
            consumed == raw.size(),
        "the frame decodes");
  Check(decoded.fields == LargeResource().fields && decoded.fds.empty() && fds.empty(), "with the regions read and closed");
  ::close(pair[1]);
}

// A shared field whose region could change or is short is malformed, and the
// descriptors are closed.
static void TestBadRegionIsMalformed() {
  control::Message m;
  m.op = 7;
  m.fields = {control::Field::Bytes(1, std::string(70000, 'r'))};
  std::vector<uint8_t> frame;
  Check(control::EncodeShared(m, {0}, &frame), "encodes");
  auto decode_with = [&](int fd) {
    std::deque<int> fds{fd};
    control::Message out;
    size_t consumed = 0;
    return control::Decode(frame.data(), frame.size(), &fds, &out, &consumed);
  };
  const int good = control::CreateSharedRegion(std::string(70000, 'r'));
  Check(good >= 0, "a region is made");
  Check(decode_with(good) == control::Parse::kFrame, "a sealed region of the right size decodes");
  Check(::fcntl(good, F_GETFD) < 0, "and is closed once read");

  const int short_region = control::CreateSharedRegion(std::string(100, 'r'));
  Check(decode_with(short_region) == control::Parse::kMalformed, "a region shorter than its count is malformed");
  Check(::fcntl(short_region, F_GETFD) < 0, "and closed");

  int pipe_fds[2];
  Check(::pipe(pipe_fds) == 0, "pipe");
  Check(decode_with(pipe_fds[1]) == control::Parse::kMalformed, "a descriptor that is no sealed region is malformed");
  Check(::fcntl(pipe_fds[1], F_GETFD) < 0, "and closed");
  ::close(pipe_fds[0]);
#if defined(__linux__)
  const int unsealed = ::memfd_create("unsealed", MFD_CLOEXEC);
  Check(unsealed >= 0 && ::ftruncate(unsealed, 70000) == 0, "an unsealed memfd");
  Check(decode_with(unsealed) == control::Parse::kMalformed, "a region its sender can still change is malformed");
#endif
  std::vector<uint8_t> zero = frame;
  std::memset(zero.data() + control::kHeaderSize + control::kFieldHeaderSize, 0, 8);
  std::deque<int> none{control::CreateSharedRegion("x")};
  control::Message out;
  size_t consumed = 0;
  Check(control::Decode(zero.data(), zero.size(), &none, &out, &consumed) == control::Parse::kMalformed,
        "a shared field of 0 bytes is malformed");
  for (int fd : none) ::close(fd);

  // A read-only descriptor of a file its sender could still truncate through
  // another one: the copy would fault. Only a sealed region is mapped.
  char path[] = "/tmp/cmux-region-test-XXXXXX";
  const int writable = ::mkstemp(path);
  Check(writable >= 0 && ::write(writable, std::string(70000, 'r').data(), 70000) == 70000, "a 70,000-byte file");
  const int read_only = ::open(path, O_RDONLY);
  Check(read_only >= 0, "opened read-only");
  Check(decode_with(read_only) == control::Parse::kMalformed, "a read-only regular file of the right size is malformed");
  Check(::fcntl(read_only, F_GETFD) < 0, "and closed");
  ::unlink(path);
  ::close(writable);

  // Two shared fields of 100 MiB each: each under kMaxSharedBytes, together over it.
  std::vector<uint8_t> over;
  auto put = [&over](uint64_t value, int size) {
    for (int i = 0; i < size; ++i) over.push_back(static_cast<uint8_t>(value >> (8 * i)));
  };
  put(2 * (control::kFieldHeaderSize + 8), 4);
  put(7, 2);
  put(2, 2);  // two descriptors
  put(0, 4);
  for (uint8_t tag : {1, 2}) {
    over.push_back(6);
    over.push_back(tag);
    put(8, 2);
    put(100ull * 1024 * 1024, 8);
  }
  std::deque<int> two{control::CreateSharedRegion("a"), control::CreateSharedRegion("b")};
  Check(control::Decode(over.data(), over.size(), &two, &out, &consumed) == control::Parse::kMalformed,
        "shared fields over kMaxSharedBytes together are malformed");
  for (int fd : two) ::close(fd);
}

// The reader pauses at the inbox's byte limit as at its message limit, so
// large payloads never pile up on the heap.
static void TestInboxByteLimit() {
  int pair[2];
  SocketPair(pair);
  Ui ui_a, ui_b;
  control::Channel a(pair[0], ui_a.Poster(), ui_a.Receiver(), ui_a.Ender());
  control::Channel::Options options;
  options.inbox_bytes_limit = 100000;
  control::Channel b(pair[1], ui_b.Poster(), ui_b.Receiver(), ui_b.Ender(), options);
  for (int i = 0; i < 20; ++i) {
    control::Message m;
    m.op = 9;
    m.fields = {control::Field::Bytes(1, std::string(70000, 'a')), control::Field::I32(2, i)};
    Check(a.Send(m), "sent");
  }
  // Let the reader fill the inbox before the UI thread drains it.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  Check(ui_b.Pump([&] { return ui_b.messages.size() == 20; }), "every message arrives");
  bool ordered = ui_b.messages.size() == 20;
  for (size_t i = 0; ordered && i < ui_b.messages.size(); ++i) {
    ordered = ui_b.messages[i].Find(2)->integer == static_cast<int64_t>(i);
  }
  Check(ordered, "in order");
  Check(ui_b.largest_batch_bytes <= 100000 + 70000, "no drain holds more than the limit and one message");
}

// Shared payloads count toward the quota: a peer that never reads reaches it.
static void TestSharedBytesCountTowardQuota() {
  int pair[2];
  SocketPair(pair);
  Ui ui;
  control::Channel a(pair[0], ui.Poster(), ui.Receiver(), ui.Ender());
  for (int i = 0; i < 1000000 && a.stats().pending_messages == 0; ++i) a.Send(Key(1, i));
  const size_t before = a.stats().pending_bytes;
  control::Message m;
  m.op = 8;
  m.fields = {control::Field::Bytes(1, std::string(1024 * 1024, 'q'))};
  Check(a.Send(m), "sent");
  Check(a.stats().pending_bytes >= before + 1024 * 1024, "the waiting region's bytes are counted");
  Check(a.stats().pending_bytes > control::kQuotaBytes && a.stats().quota_excess > 0,
        "a waiting 1 MB region is over the 256 KiB quota");
  ::close(pair[1]);
}

int main() {
  TestGolden();
  TestMalformed();
  TestOutbox();
  TestOutboxBatches();
  TestRoundTripWithDescriptors();
  TestBadLengthEnds();
  TestNeverReadingPeer();
  TestPeerClosesWithOutboxWaiting();
  TestUndeclaredDescriptorIsMalformed();
  TestCeilingSparesAnOutboxBackUnderQuota();
  TestDestroyStopsDelivery();
  TestQuotaCeiling();
  TestInboxBackPressure();
  TestSharedFieldsChoice();
  TestLargePayloadRoundTrips();
  TestNoSocketFrameOver64KiB();
  TestBadRegionIsMalformed();
  TestSharedBytesCountTowardQuota();
  TestInboxByteLimit();
  if (failures) return 1;
  std::printf("chromium_host_control_test: ok\n");
  return 0;
}
