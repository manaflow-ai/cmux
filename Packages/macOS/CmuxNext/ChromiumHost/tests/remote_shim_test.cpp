// The remote shim (client/remote_shim.mm) against a fake host on a socket pair: calls return at
// once, the preinit replay log (latest values) goes first at every attach, the attach queue never
// drops and coalesces state ops, optional ops need the HELLO, ids are minted from 1 << 20, mirror
// values pushed before an EVENT are read in that event's callback, a post's pending keys hide
// the old value until the ack, a lock push reaches cmux's lock fn (and a host's end unlocks
// what it held), and a bad frame ends the host. Built and run by
// scripts/cmux-next/tests/remote-shim-abi.test.sh; needs no CEF. One translation unit with the
// client, for the generated op ids (generated/remote_shim.inc also defines the exports).
#include "remote_shim.mm"

#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <random>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using cmux_host::control::Decode;
using cmux_host::control::Encode;
using cmux_host::control::EncodeFields;
using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::control::Parse;
using cmux_host::control::TlvReader;
using cmux_host::control::TlvWriter;
namespace control = cmux_host::control;

int failures = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                         \
    }                                                                     \
  } while (0)

// The test's main thread queue: what cmux's MainWorkScheduler is in the app.
std::mutex queue_mutex;
std::deque<std::pair<cmux_remote_main_task_fn, void*>> queue;

void PostMain(void*, cmux_remote_main_task_fn run, void* task) {
  std::lock_guard<std::mutex> lock(queue_mutex);
  queue.emplace_back(run, task);
}

// Runs posted tasks until `done` holds or `limit` passes.
bool PumpUntil(const std::function<bool()>& done, std::chrono::milliseconds limit = std::chrono::seconds(5)) {
  const auto deadline = std::chrono::steady_clock::now() + limit;
  while (!done()) {
    std::deque<std::pair<cmux_remote_main_task_fn, void*>> tasks;
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      tasks.swap(queue);
    }
    for (auto& [run, task] : tasks) run(task);
    if (std::chrono::steady_clock::now() > deadline) return false;
    if (tasks.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

// The fake host's end: frames cmux sent, and frames to send back.
struct Host {
  int fd = -1;
  std::vector<uint8_t> buffer;
  std::deque<int> fds;

  // Reads until `count` messages arrived (or 5 s pass).
  std::vector<Message> Read(size_t count) {
    std::vector<Message> out;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (out.size() < count && std::chrono::steady_clock::now() < deadline) {
      Message message;
      size_t used = 0;
      const Parse parse = buffer.empty() ? Parse::kNeedMore : Decode(buffer.data(), buffer.size(), &fds, &message, &used);
      if (parse == Parse::kFrame) {
        buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(used));
        out.push_back(std::move(message));
        continue;
      }
      if (parse == Parse::kMalformed) break;
      pollfd p{fd, POLLIN, 0};
      if (::poll(&p, 1, 50) <= 0) continue;
      uint8_t chunk[4096];
      const ssize_t n = ::read(fd, chunk, sizeof chunk);
      if (n <= 0) break;
      buffer.insert(buffer.end(), chunk, chunk + n);
    }
    return out;
  }

  void Send(const Message& message) {
    std::vector<uint8_t> bytes;
    CHECK(Encode(message, &bytes));
    CHECK(::write(fd, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
  }
};

// Reads one message at a time until `done` holds for one (or 5 s pass).
void ReadThrough(Host* host, const std::function<bool(const Message&)>& done) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    const std::vector<Message> got = host->Read(1);
    if (got.size() == 1 && done(got[0])) return;
  }
  CHECK(!"ReadThrough timed out");
}

int AttachNew(Host* host) {
  int pair[2];
  if (::socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 0;
  host->fd = pair[1];
  host->buffer.clear();
  return cmux_remote_shim_attach(pair[0], nullptr, nullptr);
}

Message Mirror(uint16_t op, int32_t browser, const char* value) {
  TlvWriter key;
  key.I32(browser);
  TlvWriter v;
  v.Str(value);
  std::string key_bytes, value_bytes;
  EncodeFields(key.fields(), &key_bytes);
  EncodeFields(v.fields(), &value_bytes);
  TlvWriter m;
  m.I32(op);
  m.Bytes(key_bytes.data(), key_bytes.size());
  m.Bytes(value_bytes.data(), value_bytes.size());
  Message message;
  message.op = cmux_remote::kOpMirror;
  message.fields = m.Take();
  return message;
}

Message Event(int kind, int browser) {
  TlvWriter w;
  w.I32(kind);
  w.I32(browser);
  w.I32(0);
  w.I64(7);
  w.I64(8);
  w.Str("s1");
  w.Str(nullptr);
  Message message;
  message.op = cmux_remote::kOpEvent;
  message.fields = w.Take();
  return message;
}

struct Seen {
  int events = 0;
  std::string state_in_event;
  std::string s2;
  int ended = -1;
  bool scheduled = false;
  int ready = 0;
  std::vector<uint32_t> replies;
};
Seen seen;

Message Hello(const char* wire) {
  TlvWriter w;
  w.Str(wire);
  const char* exports[] = {"cmux_shim_tab_evaluate", "cmux_shim_browser_ime_set_composition",
                           "cmux_shim_browser_ime_commit_text", "cmux_shim_browser_ime_finish_composing",
                           "cmux_shim_browser_ime_cancel_composition"};
  w.StrList(exports, sizeof exports / sizeof exports[0]);
  Message message;
  message.op = cmux_host::control::kOpHello;
  message.fields = w.Take();
  return message;
}

void OnReady(void*) {
  ++seen.ready;
}

void OnReply(void*, uint32_t token, const void* fields, size_t length) {
  std::vector<cmux_host::control::Field> decoded;
  CHECK(cmux_host::control::DecodeFields(std::string_view(static_cast<const char*>(fields), length), &decoded));
  TlvReader r(std::move(decoded));
  CHECK(r.I32() == 1 && r.ok() && r.AtEnd());
  seen.replies.push_back(token);
}

std::string NavigationState(int browser) {
  char* s = cmux_shim_tab_navigation_state(browser);
  std::string out = s ? s : "<null>";
  cmux_shim_free(s);
  return out;
}

std::string ExtensionList(int browser) {
  char* s = cmux_shim_ext_list(browser);
  std::string out = s ? s : "<null>";
  cmux_shim_free(s);
  return out;
}

void OnEvent(void*, int, int browser_id, int, int64_t a, int64_t b, const char*, const char* s2) {
  ++seen.events;
  CHECK(a == 7 && b == 8);
  seen.s2 = s2;
  seen.state_in_event = NavigationState(browser_id);
}

void OnSchedule(void*, int64_t) {
  seen.scheduled = true;
}

void OnEnded(void*, int reason) {
  seen.ended = reason;
}

uint64_t stats_unhandled_input_acks() {
  cmux_remote_shim_stats stats = {};
  cmux_remote_shim_get_stats(&stats);
  return stats.input_acks_unhandled;
}

// The input acks (kOpInputAck) the callback got, in order.
struct InputAck {
  int32_t browser, kind;
  uint32_t seq;
  bool operator==(const InputAck& other) const {
    return browser == other.browser && kind == other.kind && seq == other.seq;
  }
};
std::vector<InputAck> input_acks;
int input_ack_ctx = 0;

void OnInputAck(void* ctx, int32_t browser, int32_t kind, uint32_t seq) {
  CHECK(ctx == &input_ack_ctx);
  input_acks.push_back(InputAck{browser, kind, seq});
}

Message InputAckMessage(const std::vector<InputAck>& records) {
  TlvWriter w;
  for (const InputAck& record : records) {
    w.I32(record.browser);
    w.I32(record.kind);
    w.U32(record.seq);
  }
  Message message;
  message.op = cmux_host::control::kOpInputAck;
  message.fields = w.Take();
  return message;
}

// The ordering case through the real sender (task 092): the runtime's Post, PostInput and
// OrderInput, its channel and outbox on a socket with a small buffer (so placements wait and
// coalesce), the host's FrameQueue for ring frames and its OrderedStream. 10,000 ring keys
// interleaved with page activations, devtools placements (keyed, ordered), control-channel
// wheels, ring clicks and ring wheel bursts across 2 pages: every key lands on the page active
// when it was written, every click and wheel meets the placement cmux had when it sent it.
void TestOrderingThroughTheRuntime() {
  int pair[2];
  CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
  const int small = 4096;
  ::setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, sizeof small);
  ::setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &small, sizeof small);
  Host host;
  host.fd = pair[1];
  CHECK(cmux_remote_shim_attach(pair[0], nullptr, nullptr) == 1);
  const int ready = seen.ready;
  host.Send(Hello(cmux_remote::kWireID));
  CHECK(PumpUntil([&] { return seen.ready == ready + 1; }));
  cmux_remote_shim_stats stats = {};
  cmux_remote_shim_get_stats(&stats);
  const uint64_t coalesced_before = stats.coalesced;

  const int first = cmux_remote::kFirstMintedBrowserID;
  const int pages[2] = {first, first + 1};
  const int sentinel = first + 100;
  auto index = [&](int64_t browser) { return browser == pages[1] ? 1 : 0; };

  // cmux's view.
  int active = pages[0];
  int placement[2] = {0, 0};
  std::vector<int> key_page;
  std::map<std::pair<int, int>, int64_t> wheel_sent;  // (page, placement) -> summed dy
  // The host's view.
  struct HostView {
    int active = 0;
    int placement[2] = {0, 0};
    std::vector<int32_t> keys;
    std::map<std::pair<int, int>, int64_t> wheel;
    size_t misrouted = 0, wrong_clicks = 0, wrong_wheels = 0, wrong_control_wheels = 0;
    bool sentinel = false;
  } got;
  got.active = pages[0];

  control::OrderedStream stream([&](std::vector<Message> run) {
    for (const Message& m : run) {
      switch (m.op) {
        case cmux_remote::kOpTabActivate:
          got.active = static_cast<int>(m.fields.at(0).integer);
          break;
        case cmux_remote::kOpDevtoolsSetPlacement:
          got.placement[index(m.fields.at(0).integer)] = static_cast<int>(m.fields.at(4).integer);
          break;
        case cmux_remote::kOpBrowserSendWheel:
          if (m.fields.at(1).real != got.placement[index(m.fields.at(0).integer)]) ++got.wrong_control_wheels;
          break;
        case cmux_remote::kOpStop:
          if (m.fields.at(0).integer == sentinel) got.sentinel = true;
          break;
        default:
          break;
      }
    }
  });
  stream.AttachInput([&](const cmux_host::Header& h) {
    const int page = static_cast<int>(h.t1 & 0xffffffffu);
    if (page != got.active) ++got.misrouted;
    if (h.kind == cmux_host::kKey) {
      got.keys.push_back(h.v[1]);
    } else if (h.kind == cmux_host::kMouse) {
      if (h.v[0] != got.placement[index(page)]) ++got.wrong_clicks;
    } else if (h.kind == cmux_host::kWheel) {
      if (h.v[0] != got.placement[index(page)]) ++got.wrong_wheels;
      got.wheel[{page, got.placement[index(page)]}] += h.v[3];
    }
  });
  CHECK(stream.OpenInput() == control::OrderedStream::Result::kOk);
  bool malformed = false;
  cmux_host::FrameQueue ring(cmux_host::kFrameBacklog);
  ring.MarkReady();
  std::deque<cmux_host::Header> ring_held;  // frames AddInput refused: the ring keeps them

  // The host reads what the socket has, and what the ring has.
  auto host_step = [&](std::mt19937& rng, int wait_ms) {
    const bool control_first = rng() % 2 == 0;
    auto control_side = [&] {
      std::vector<Message> batch;
      pollfd p{host.fd, POLLIN, 0};
      while (::poll(&p, 1, batch.empty() ? wait_ms : 0) > 0) {
        uint8_t chunk[4096];
        const ssize_t n = ::read(host.fd, chunk, sizeof chunk);
        if (n <= 0) break;
        host.buffer.insert(host.buffer.end(), chunk, chunk + n);
        for (;;) {
          Message m;
          size_t used = 0;
          if (Decode(host.buffer.data(), host.buffer.size(), &host.fds, &m, &used) != Parse::kFrame) break;
          host.buffer.erase(host.buffer.begin(), host.buffer.begin() + static_cast<std::ptrdiff_t>(used));
          batch.push_back(std::move(m));
        }
        if (batch.size() > 64) break;
      }
      if (!batch.empty()) malformed |= stream.AddControl(std::move(batch)) == control::OrderedStream::Result::kMalformed;
    };
    auto ring_side = [&] {
      for (cmux_host::QueuedFrame& frame : ring.Take()) ring_held.push_back(frame.header);
      while (!ring_held.empty()) {
        const control::OrderedStream::Result r = stream.AddInput(ring_held.front());
        malformed |= r == control::OrderedStream::Result::kMalformed;
        if (r == control::OrderedStream::Result::kFull) break;
        ring_held.pop_front();
      }
    };
    if (control_first) {
      control_side();
      ring_side();
    } else {
      ring_side();
      control_side();
    }
  };

  // cmux writes a ring frame: OrderInput's seqs, the page in t1's low bits.
  auto write = [&](cmux_host::Header h, int page) {
    uint32_t ctl = 0;
    h.seq = cmux_remote_shim_order_input(&ctl);
    CHECK(h.seq != 0);
    h.t1 = static_cast<uint32_t>(page);
    cmux_host::SetCtlSeq(&h, ctl);
    CHECK(ring.Add(h, std::string()) != cmux_host::FrameQueue::Push::kFull);
  };
  auto place = [&](int page, std::mt19937& rng) {
    placement[index(page)] = 100 + static_cast<int>(rng() % 1000);
    cmux_shim_devtools_set_placement(page, nullptr, 0, 0, placement[index(page)], 10);
  };

  std::mt19937 rng(92);
  size_t activations = 0, placements = 0, control_wheels = 0, clicks = 0, ring_wheels = 0;
  int32_t keys = 0;
  while (keys < 10000) {
    const unsigned roll = rng() % 100;
    if (roll < 8) {
      active = active == pages[0] ? pages[1] : pages[0];
      CHECK(cmux_shim_tab_activate(active) == 1);
      ++activations;
    } else if (roll < 16) {
      const int page = pages[rng() % 2];
      for (unsigned n = 1 + rng() % 3; n > 0; --n) {  // a burst: the outbox replaces waiting ones
        place(page, rng);
        ++placements;
      }
    } else if (roll < 20) {
      CHECK(cmux_shim_browser_send_wheel(active, placement[index(active)], 1, 0, 3, 1, 2, 0, 0) == 1);
      ++control_wheels;
      if (rng() % 2 == 0) {
        place(active, rng);  // a placement right after the wheel must not take the one before it
        ++placements;
      }
    } else if (roll < 25) {
      cmux_host::Header h;
      h.kind = cmux_host::kMouse;
      h.v[0] = placement[index(active)];
      h.v[2] = 1;  // down
      write(h, active);
      ++clicks;
    } else if (roll < 32) {
      for (unsigned n = 1 + rng() % 4; n > 0; --n) {  // a burst: the ring queue folds wheels
        cmux_host::Header h;
        h.kind = cmux_host::kWheel;
        h.v[0] = placement[index(active)];
        h.v[3] = 1 + static_cast<int32_t>(rng() % 5);
        wheel_sent[{active, placement[index(active)]}] += h.v[3];
        write(h, active);
        ++ring_wheels;
        if (rng() % 3 == 0) {
          place(active, rng);  // an ordered op inside the burst: the wheels around it stay apart
          ++placements;
        }
      }
    } else {
      cmux_host::Header h;
      h.kind = cmux_host::kKey;
      h.v[1] = keys++;
      key_page.push_back(active);
      write(h, active);
    }
    if (rng() % 100 < 3) host_step(rng, 0);
  }
  cmux_shim_stop(sentinel);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!(got.sentinel && ring_held.empty() && ring.size() == 0 && stream.held_input() == 0 &&
           stream.held_control() == 0) &&
         std::chrono::steady_clock::now() < deadline) {
    host_step(rng, 20);
  }
  cmux_remote_shim_get_stats(&stats);
  const uint64_t outbox_coalesced = stats.coalesced - coalesced_before;

  CHECK(!malformed);
  CHECK(got.sentinel && stream.held_input() == 0 && stream.held_control() == 0);
  CHECK(got.misrouted == 0);
  CHECK(got.wrong_clicks == 0 && got.wrong_wheels == 0 && got.wrong_control_wheels == 0);
  CHECK(got.wheel == wheel_sent);
  std::vector<int32_t> want(static_cast<size_t>(keys));
  for (int32_t i = 0; i < keys; ++i) want[static_cast<size_t>(i)] = i;
  CHECK(got.keys == want);
  CHECK(activations > 500 && placements > 500 && control_wheels > 200 && clicks > 200 && ring_wheels > 500);
  CHECK(outbox_coalesced > 0 && ring.coalesced() > 0);  // both coalescing paths ran
  std::fprintf(stderr,
               "remote shim ordering: %d keys, %zu activations, %zu placements (%llu coalesced), %zu control "
               "wheels, %zu clicks, %zu ring wheels (%llu folded)\n",
               keys, activations, placements, static_cast<unsigned long long>(outbox_coalesced), control_wheels,
               clicks, ring_wheels, static_cast<unsigned long long>(ring.coalesced()));
  cmux_remote_shim_detach();
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
  ::close(host.fd);
}
// Every frame the fake host has within `quiet` of the last one.
std::vector<Message> Drain(Host* host, std::chrono::milliseconds quiet = std::chrono::milliseconds(200)) {
  std::vector<Message> out;
  for (;;) {
    PumpUntil([] { return false; }, std::chrono::milliseconds(20));
    pollfd p{host->fd, POLLIN, 0};
    if (host->buffer.empty() && ::poll(&p, 1, static_cast<int>(quiet.count())) <= 0) return out;
    const std::vector<Message> got = host->Read(1);
    if (got.empty()) return out;
    out.push_back(got[0]);
  }
}

// The saver frames among `messages`: "<version> <enabled> <scheme or <null>>".
std::vector<std::string> SaverFrames(const std::vector<Message>& messages) {
  std::vector<std::string> out;
  for (const Message& m : messages) {
    if (m.op != cmux_host::kOpEnergySaver) continue;
    TlvReader r(m.fields);
    const int32_t version = r.I32();
    const int32_t enabled = r.I32();
    const std::optional<std::string> scheme = r.Str();
    CHECK(r.ok() && r.AtEnd() && m.token == 0);
    out.push_back(std::to_string(version) + " " + std::to_string(enabled) + " " + scheme.value_or("<null>"));
  }
  return out;
}

// A host HELLO of this wire listing `exports`.
Message HelloListing(std::vector<const char*> exports) {
  TlvWriter w;
  w.Str(cmux_remote::kWireID);
  w.StrList(exports.data(), static_cast<int>(exports.size()));
  Message message;
  message.op = cmux_host::control::kOpHello;
  message.fields = w.Take();
  return message;
}

void SayHello(Host* host, std::vector<const char*> exports) {
  const int ready = seen.ready;
  host->Send(HelloListing(std::move(exports)));
  CHECK(PumpUntil([&] { return seen.ready == ready + 1; }));
}

// cmux_shim_set_energy_saver in host mode: the host's end sees kOpEnergySaver,
// versioned, on each edge; the call answers 1 only for a host whose HELLO listed the saver; a new
// host gets the saver once while it is on, and nothing while it is off; a host without the saver
// gets no frame.
void TestEnergySaver() {
  const std::string want_on = std::to_string(cmux_host::kEnergySaverVersion) + " 1 cmux-page";
  const std::string want_off = std::to_string(cmux_host::kEnergySaverVersion) + " 0 cmux-page";

  // No host: kept for the next one, answered 0.
  CHECK(cmux_remote_shim_attached() == 0);
  CHECK(cmux_shim_set_energy_saver(1, "cmux-page") == 0);
  Host first;
  CHECK(AttachNew(&first) == 1);
  CHECK(SaverFrames(Drain(&first)).empty());  // it waits for the HELLO, which says whether the host has it
  SayHello(&first, {cmux_host::kEnergySaverHelloName});
  CHECK(SaverFrames(Drain(&first)) == std::vector<std::string>({want_on}));
  // Each edge is one frame.
  CHECK(cmux_shim_set_energy_saver(0, "cmux-page") == 1);
  CHECK(cmux_shim_set_energy_saver(1, nullptr) == 1);
  CHECK(cmux_shim_set_energy_saver(0, "cmux-page") == 1);
  CHECK(SaverFrames(Drain(&first)) ==
        std::vector<std::string>({want_off, std::to_string(cmux_host::kEnergySaverVersion) + " 1 <null>", want_off}));
  cmux_remote_shim_detach();
  ::close(first.fd);

  // Off: a new host starts with it off and gets no frame.
  Host second;
  CHECK(AttachNew(&second) == 1);
  SayHello(&second, {cmux_host::kEnergySaverHelloName});
  CHECK(SaverFrames(Drain(&second)).empty());
  CHECK(cmux_shim_set_energy_saver(1, "cmux-page") == 1);
  CHECK(SaverFrames(Drain(&second)) == std::vector<std::string>({want_on}));
  cmux_remote_shim_detach();
  ::close(second.fd);
  // On: the next host gets it after its HELLO. An edge before that HELLO waits for it too, and
  // the call cannot say whether it applies.
  Host third;
  CHECK(AttachNew(&third) == 1);
  CHECK(cmux_shim_set_energy_saver(1, "cmux-page") == 0);
  CHECK(SaverFrames(Drain(&third)).empty());
  SayHello(&third, {cmux_host::kEnergySaverHelloName});
  CHECK(SaverFrames(Drain(&third)) == std::vector<std::string>({want_on, want_on}));
  cmux_remote_shim_detach();
  ::close(third.fd);

  // A host whose fork has no saver: no frame, and the call answers 0.
  Host fourth;
  CHECK(AttachNew(&fourth) == 1);
  SayHello(&fourth, {});
  CHECK(cmux_shim_set_energy_saver(0, "cmux-page") == 0);
  CHECK(SaverFrames(Drain(&fourth)).empty());
  cmux_remote_shim_detach();
  ::close(fourth.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
}

// The provider link frames among `messages`: "<socket or <none>> <link id>".
std::vector<std::string> ProviderLinkFrames(const std::vector<Message>& messages) {
  std::vector<std::string> out;
  for (const Message& m : messages) {
    if (m.op != cmux_host::kOpProviderLink) continue;
    const std::optional<cmux_host::ProviderLinkConfig> config = cmux_host::DecodeProviderLink(m.fields);
    CHECK(config.has_value() && m.token == 0);
    if (config) out.push_back(config->socket.value_or("<none>") + " " + config->link_id);
  }
  return out;
}

// The host watch: a host whose HELLO lists kHangWatchHelloName has the
// seqs cmux_remote_shim_order_input gives counted against its kOpInputDispatched. The callback
// hears the first waiting seq, a dispatch that leaves later ones waiting, the dispatch that
// settles them, and each kOpHostHang; a detach settles what waited. A host without the name
// counts nothing, and a malformed ack ends the host.
struct WatchEvent {
  int32_t event;
  int64_t a;
  int64_t b;
  bool operator==(const WatchEvent& other) const { return event == other.event && a == other.a && b == other.b; }
};
std::vector<WatchEvent> watch_events;
void OnHostWatch(void*, int32_t event, int64_t a, int64_t b) {
  watch_events.push_back({event, a, b});
}

void TestHostWatch() {
  namespace hang = cmux_host::hang;
  cmux_remote_shim_set_host_watch(nullptr, &OnHostWatch);
  watch_events.clear();

  Host watched;
  CHECK(AttachNew(&watched) == 1);
  SayHello(&watched, {hang::kHangWatchHelloName});
  uint32_t ctl = 0;
  const uint32_t first = cmux_remote_shim_order_input(&ctl);
  const uint32_t second = cmux_remote_shim_order_input(&ctl);
  const uint32_t third = cmux_remote_shim_order_input(&ctl);
  CHECK(first != 0 && second != 0 && third != 0);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_OUTSTANDING, 0, 0}}));
  watch_events.clear();
  watched.Send(hang::DispatchedMessage(second));
  CHECK(PumpUntil([] { return !watch_events.empty(); }));
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_PROGRESS, 0, 0}}));
  watch_events.clear();
  watched.Send(hang::HangMessage({300'000'000, hang::kHangDumped}));
  watched.Send(hang::DispatchedMessage(third));
  CHECK(PumpUntil([] { return watch_events.size() == 2; }));
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_HANG, 300'000'000, hang::kHangDumped},
                                                  {CMUX_REMOTE_HOST_INPUT_SETTLED, 0, 0}}));
  watch_events.clear();
  // Waiting input goes with the host.
  CHECK(cmux_remote_shim_order_input(&ctl) != 0);
  CHECK(watch_events.size() == 1 && watch_events[0].event == CMUX_REMOTE_HOST_INPUT_OUTSTANDING);
  watch_events.clear();
  cmux_remote_shim_detach();
  ::close(watched.fd);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_SETTLED, 0, 0}}));
  watch_events.clear();

  // Control-channel input (the wheel, until the ring carries it): each goes with a token, and the
  // host's kOpAck of it, sent once the op ran, is its ack. A wheel waits from its post on.
  Host wheels;
  CHECK(AttachNew(&wheels) == 1);
  SayHello(&wheels, {hang::kHangWatchHelloName});
  Drain(&wheels);
  watch_events.clear();
  CHECK(cmux_shim_browser_send_wheel(7, 10, 20, 0, -3, 1, 0, 0, 0) == 1);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_OUTSTANDING, 0, 0}}));
  CHECK(cmux_shim_browser_send_wheel(7, 10, 20, 0, -3, 1, 0, 0, 0) == 1);
  CHECK(watch_events.size() == 1);  // the second joins the wait
  watch_events.clear();
  std::vector<uint32_t> wheel_tokens;
  for (const Message& message : wheels.Read(2)) {
    CHECK(message.op == cmux_remote::kOpBrowserSendWheel && message.token != 0);
    wheel_tokens.push_back(message.token);
  }
  CHECK(wheel_tokens.size() == 2 && wheel_tokens[0] != wheel_tokens[1]);
  auto host_ack = [](uint32_t token) {
    Message ack;
    ack.op = cmux_remote::kOpAck;
    ack.reply = true;
    ack.token = token;
    return ack;
  };
  if (wheel_tokens.size() == 2) {
    wheels.Send(host_ack(wheel_tokens[0]));
    CHECK(PumpUntil([] { return !watch_events.empty(); }));
    CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_PROGRESS, 0, 0}}));
    watch_events.clear();
    wheels.Send(host_ack(wheel_tokens[1]));
    CHECK(PumpUntil([] { return !watch_events.empty(); }));
    CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_SETTLED, 0, 0}}));
    watch_events.clear();
  }
  // Ring and control input wait together: the ring's dispatch alone is progress, the wheel's ack
  // settles both.
  const uint32_t ring = cmux_remote_shim_order_input(&ctl);
  CHECK(cmux_shim_browser_send_locked_mouse_move(7, 1, 1, 0) == 1);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_OUTSTANDING, 0, 0}}));
  watch_events.clear();
  const std::vector<Message> moved = wheels.Read(1);
  CHECK(moved.size() == 1 && moved[0].op == cmux_remote::kOpBrowserSendLockedMouseMove && moved[0].token != 0);
  wheels.Send(hang::DispatchedMessage(ring));
  CHECK(PumpUntil([] { return !watch_events.empty(); }));
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_PROGRESS, 0, 0}}));
  watch_events.clear();
  if (moved.size() == 1) wheels.Send(host_ack(moved[0].token));
  CHECK(PumpUntil([] { return !watch_events.empty(); }));
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_SETTLED, 0, 0}}));
  watch_events.clear();
  // A wheel the host never acks (it stopped) waits until the host goes.
  CHECK(cmux_shim_browser_send_wheel(7, 10, 20, 0, -3, 1, 0, 0, 0) == 1);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_OUTSTANDING, 0, 0}}));
  watch_events.clear();
  PumpUntil([] { return false; }, std::chrono::milliseconds(50));
  CHECK(watch_events.empty());
  cmux_remote_shim_detach();
  ::close(wheels.fd);
  CHECK(watch_events == std::vector<WatchEvent>({{CMUX_REMOTE_HOST_INPUT_SETTLED, 0, 0}}));
  watch_events.clear();

  // A host that does not ack its dispatch: nothing is counted (no busy banner for it), and its
  // wheels carry no token.
  Host plain;
  CHECK(AttachNew(&plain) == 1);
  SayHello(&plain, {});
  Drain(&plain);
  CHECK(cmux_remote_shim_order_input(&ctl) != 0);
  CHECK(cmux_shim_browser_send_wheel(7, 10, 20, 0, -3, 1, 0, 0, 0) == 1);
  {
    const std::vector<Message> got = plain.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpBrowserSendWheel && got[0].token == 0);
  }
  CHECK(watch_events.empty());
  cmux_remote_shim_detach();
  ::close(plain.fd);
  CHECK(watch_events.empty());

  // A malformed ack (seq 0) is a bad message: the host is ended.
  Host bad;
  CHECK(AttachNew(&bad) == 1);
  SayHello(&bad, {hang::kHangWatchHelloName});
  seen.ended = -1;
  Message zero = hang::DispatchedMessage(1);
  zero.fields[0].integer = 0;
  bad.Send(zero);
  CHECK(PumpUntil([] { return seen.ended == CMUX_REMOTE_END_MALFORMED; }));
  ::close(bad.fd);
  cmux_remote_shim_set_host_watch(nullptr, nullptr);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
}

// The lock fn's calls: "<event> <browser> <detail>".
std::vector<std::string> lock_calls;
void OnLock(void* context, int event, int browser_id, int detail) {
  CHECK(context == &lock_calls);
  lock_calls.push_back(std::to_string(event) + " " + std::to_string(browser_id) + " " + std::to_string(detail));
}

Message LockPush(int event, int browser, int detail) {
  TlvWriter w;
  w.I32(CMUX_SHIM_LOCK);
  w.I32(browser);
  w.I32(event);
  w.I64(detail);
  w.I64(0);
  w.Str("");
  w.Str("");
  Message message;
  message.op = cmux_remote::kOpEvent;
  message.fields = w.Take();
  return message;
}

// The lock handler frames among `messages`: their installed flag.
std::vector<int> LockHandlerFrames(const std::vector<Message>& messages) {
  std::vector<int> out;
  for (const Message& m : messages) {
    if (m.op != cmux_remote::kOpSetLockHandler) continue;
    const std::optional<bool> installed = cmux_host::DecodeLockHandler(m.fields);
    CHECK(installed.has_value() && m.token == 0);
    out.push_back(installed.value_or(false) ? 1 : 0);
  }
  return out;
}

// cmux_remote_shim_set_provider_link: the host's end sees kOpProviderLink after its HELLO; the call
// answers 1 only for a host whose HELLO listed the link; every later host gets it once; a host
// without the link gets no frame; a socket with no credential is refused.
void TestProviderLink() {
  CHECK(cmux_remote_shim_set_provider_link("/s.sock", "", "L1", 1, 2) == 0);
  CHECK(cmux_remote_shim_set_provider_link("/s.sock", "cred", "L1", 1, 2) == 0);  // no host: kept
  Host first;
  CHECK(AttachNew(&first) == 1);
  CHECK(ProviderLinkFrames(Drain(&first)).empty());  // it waits for the HELLO
  SayHello(&first, {cmux_host::kProviderLinkHelloName});
  CHECK(ProviderLinkFrames(Drain(&first)) == std::vector<std::string>({"/s.sock L1"}));
  CHECK(cmux_remote_shim_set_provider_link("/t.sock", "cred2", "L1", 1, 2) == 1);
  CHECK(ProviderLinkFrames(Drain(&first)) == std::vector<std::string>({"/t.sock L1"}));
  cmux_remote_shim_detach();
  ::close(first.fd);

  Host second;  // a restarted host gets the last one
  CHECK(AttachNew(&second) == 1);
  SayHello(&second, {cmux_host::kProviderLinkHelloName});
  CHECK(ProviderLinkFrames(Drain(&second)) == std::vector<std::string>({"/t.sock L1"}));
  CHECK(cmux_remote_shim_set_provider_link(nullptr, nullptr, nullptr, 0, 0) == 1);  // the link ends
  CHECK(ProviderLinkFrames(Drain(&second)) == std::vector<std::string>({"<none> "}));
  cmux_remote_shim_detach();
  ::close(second.fd);

  CHECK(cmux_remote_shim_set_provider_link("/s.sock", "cred", "L1", 1, 2) == 0);
  Host third;  // a host without the link
  CHECK(AttachNew(&third) == 1);
  SayHello(&third, {});
  CHECK(cmux_remote_shim_set_provider_link("/s.sock", "cred", "L1", 1, 2) == 0);
  CHECK(ProviderLinkFrames(Drain(&third)).empty());
  CHECK(cmux_remote_shim_set_provider_link(nullptr, nullptr, nullptr, 0, 0) == 0);
  cmux_remote_shim_detach();
  ::close(third.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
}

// cmux_shim_set_lock_handler in host mode (task 229): only the handler's on/off goes to a host
// whose HELLO listed kLocksHelloName, again to every later host; the host's CMUX_SHIM_LOCK
// pushes reach cmux's lock fn and never its event fn; a host that ends unlocks every lock it may
// hold; a host without the delegate gets no frame and the call answers 0.
void TestLocks() {
  lock_calls.clear();
  CHECK(cmux_remote_shim_attached() == 0);
  CHECK(cmux_shim_set_lock_handler(&OnLock, &lock_calls) == 0);  // no host: kept for the next one
  Host first;
  CHECK(AttachNew(&first) == 1);
  CHECK(LockHandlerFrames(Drain(&first)).empty());  // it waits for the HELLO
  SayHello(&first, {cmux_host::kLocksHelloName});
  CHECK(LockHandlerFrames(Drain(&first)) == std::vector<int>({1}));
  const int events = seen.events;
  const int browser = cmux_remote::kFirstMintedBrowserID;
  first.Send(LockPush(CMUX_SHIM_POINTER_LOCK_REQUESTED, browser, 1));
  first.Send(LockPush(CMUX_SHIM_KEYBOARD_LOCK_REQUESTED, browser + 1, 1));
  first.Send(LockPush(CMUX_SHIM_KEYBOARD_LOCK_REQUESTED, browser + 2, 0));
  first.Send(LockPush(CMUX_SHIM_KEYBOARD_UNLOCKED, browser + 2, 0));
  first.Send(LockPush(9, browser, 0));  // an event this side does not know: dropped
  CHECK(PumpUntil([] { return lock_calls.size() == 4; }));
  const std::string b0 = std::to_string(browser), b1 = std::to_string(browser + 1), b2 = std::to_string(browser + 2);
  CHECK(lock_calls == std::vector<std::string>({"0 " + b0 + " 1", "2 " + b1 + " 1", "2 " + b2 + " 0", "3 " + b2 + " 0"}));
  CHECK(seen.events == events);  // cmux's event fn never sees a lock push
  // The host ends: what it may hold is unlocked, pointer first.
  lock_calls.clear();
  cmux_remote_shim_detach();
  CHECK(lock_calls == std::vector<std::string>({"1 " + b0 + " 0", "3 " + b1 + " 0"}));
  ::close(first.fd);

  // A host whose fork has no lock delegate: no frame, and the call answers 0.
  lock_calls.clear();
  Host second;
  CHECK(AttachNew(&second) == 1);
  SayHello(&second, {});
  CHECK(LockHandlerFrames(Drain(&second)).empty());
  CHECK(cmux_shim_set_lock_handler(&OnLock, &lock_calls) == 0);
  CHECK(LockHandlerFrames(Drain(&second)).empty());
  cmux_remote_shim_detach();
  CHECK(lock_calls.empty());
  ::close(second.fd);

  // The next host gets the handler after its HELLO; removing it sends off, once.
  Host third;
  CHECK(AttachNew(&third) == 1);
  SayHello(&third, {cmux_host::kLocksHelloName});
  CHECK(LockHandlerFrames(Drain(&third)) == std::vector<int>({1}));
  CHECK(cmux_shim_set_lock_handler(nullptr, nullptr) == 1);
  CHECK(cmux_shim_set_lock_handler(nullptr, nullptr) == 0);  // already off: nothing to send
  CHECK(LockHandlerFrames(Drain(&third)) == std::vector<int>({0}));
  third.Send(LockPush(CMUX_SHIM_POINTER_LOCK_REQUESTED, browser, 0));
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
  CHECK(lock_calls.empty());  // with no handler a push is dropped
  cmux_remote_shim_detach();
  ::close(third.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
}

// The fence rights cmux_remote_shim_page_resize sent (cmux_remote_shim_set_fence_sender): there
// is no Mach off macOS, so the fenced path is driven through this one.
struct FenceSend {
  unsigned int channel;
  unsigned int fence;
  uint64_t seq;
};
std::vector<FenceSend> fence_sends;
int fence_send_result = 1;
int RecordFenceSend(unsigned int channel, unsigned int fence, uint64_t seq) {
  fence_sends.push_back({channel, fence, seq});
  return fence_send_result;
}

}  // namespace

int main() {
  // ABI identity and the local exports.
  CHECK(std::strcmp(cmux_shim_abi_id(), CMUX_TEST_ABI_ID) == 0);
  char err[16] = "x";
  CHECK(cmux_shim_load("/nonexistent", err, sizeof err) == 1 && err[0] == '\0');
  CHECK(cmux_shim_prepare_application() == 1);
  CHECK(cmux_shim_password_entry_size() == static_cast<int>(sizeof(cmux_shim_password_entry)));
  cmux_shim_do_work();

  // Before attach: mints, a queued post, queued preinit ops, a mirror read that is a fault.
  CHECK(cmux_shim_tab_add(1, "https://a.test/", 0, 1) == cmux_remote::kFirstMintedBrowserID);
  CHECK(cmux_shim_tab_add(1, "https://b.test/", 1, 0) == cmux_remote::kFirstMintedBrowserID + 1);
  CHECK(cmux_shim_create_window(5, nullptr, 800, 600, "https://c.test/", nullptr) == 1);
  CHECK(cmux_shim_devtools_call(1, "Page.enable", "{}") == cmux_remote::kFirstMintedDevToolsID);
  cmux_shim_set_background_color(0xff102030u);
  CHECK(cmux_shim_page_scheme_add("docs", "/tmp", nullptr) == 1);
  // The in-process shim's own refusals: nothing is queued for them.
  CHECK(cmux_shim_page_scheme_add("cmux.settings", "/tmp", nullptr) == 0);  // reserved
  CHECK(cmux_shim_page_scheme_add("no spaces", "/tmp", nullptr) == 0);
  CHECK(cmux_shim_page_scheme_add_first_party("docs", "/tmp", nullptr) == 0);  // not reserved
  CHECK(cmux_shim_page_scheme_add_first_party_dynamic("cmux.app", "/tmp", nullptr, nullptr, "../x") == 0);
  CHECK(cmux_shim_add_native_messaging_dir("", 1) == 0);
  CHECK(cmux_shim_window_count() == 0);
  cmux_remote_shim_stats stats = {};
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.reads_unattached == 1);
  {
    // No host yet: the ring writer writes no frame, and no input seq is taken.
    uint32_t ctl = 99;
    CHECK(cmux_remote_shim_order_input(&ctl) == 0 && ctl == 0);
  }

  const char* switches[] = {"enable-logging", "v=1", nullptr};
  CHECK(cmux_shim_initialize("/fw", "/app", "/helper", "/cache", nullptr, 0, "en-US", nullptr, switches, nullptr,
                             &OnSchedule, &OnEvent, nullptr) == 1);
  CHECK(cmux_shim_initialize("/fw", "/app", "/helper", "/cache", nullptr, 0, nullptr, nullptr, nullptr, nullptr,
                             &OnSchedule, &OnEvent, nullptr) == 0);
  // After initialize a preinit export still goes in the replay log, so it leads INITIALIZE.
  cmux_shim_set_new_tab_page_url("cmux-page://new-tab/");

  // The attach queue never drops: past the channel's quota it counts the excess, and a state op
  // replaces its waiting predecessor.
  const int first = cmux_remote::kFirstMintedBrowserID;
  cmux_shim_set_zoom_level(first, 1.0);
  cmux_shim_set_zoom_level(first, 2.0);
  constexpr int kQueuedStops = static_cast<int>(cmux_host::control::kQuotaMessages) + 1000;
  for (int i = 0; i < kQueuedStops; ++i) cmux_shim_stop(first);
  cmux_shim_set_zoom_level(first, 3.0);
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.coalesced == 2);
  CHECK(stats.quota_excess > 0);
  CHECK(stats.unsendable == 0);
  // An optional op waits for the host's HELLO, and the posts after it keep their place.
  CHECK(cmux_shim_tab_set_frozen(first, 1) == 1);
  cmux_shim_reload(first);

  CHECK(cmux_remote_shim_attach(3, nullptr, nullptr) == 0);  // not configured
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ended = &OnEnded;
  callbacks.ready = &OnReady;
  callbacks.reply = &OnReply;
  cmux_remote_shim_configure(&callbacks);

  Host host;
  CHECK(AttachNew(&host) == 1);
  CHECK(cmux_remote_shim_attached() == 1);
  uint32_t scheme_token = 0;
  {
    // HELLO, the replay log in call order, INITIALIZE, then the posts in call order up to the
    // optional op.
    std::vector<uint16_t> want = {
        cmux_host::control::kOpHello,     cmux_remote::kOpSetBackgroundColor, cmux_remote::kOpPageSchemeAdd,
        cmux_remote::kOpSetNewTabPageUrl, cmux_remote::kOpInitialize,         cmux_remote::kOpTabAdd,
        cmux_remote::kOpTabAdd,           cmux_remote::kOpCreateWindow,       cmux_remote::kOpDevtoolsCall};
    want.insert(want.end(), kQueuedStops, cmux_remote::kOpStop);
    want.push_back(cmux_remote::kOpSetZoomLevel);
    std::vector<Message> got = host.Read(want.size());
    CHECK(got.size() == want.size());
    for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK(got[i].op == want[i]);
    if (got.size() == want.size()) {
      TlvReader zoom(got.back().fields);
      CHECK(zoom.I32() == first && zoom.F64() == 3.0 && zoom.ok() && zoom.AtEnd());
      TlvReader hello(got[0].fields);
      CHECK(hello.Str() == std::optional<std::string>(cmux_remote::kWireID));
      CHECK(hello.Str() == std::optional<std::string>(cmux_remote::kShimAbiID));
      CHECK(hello.ok() && hello.AtEnd());
      got.erase(got.begin());
      TlvReader color(got[0].fields);
      CHECK(color.U32() == 0xff102030u && color.ok() && color.AtEnd());
      CHECK(got[0].token == 0);
      scheme_token = got[1].token;  // a non-void preinit asks the host's verdict
      CHECK(scheme_token != 0);
      TlvReader url(got[2].fields);
      CHECK(url.Str() == std::optional<std::string>("cmux-page://new-tab/"));
      TlvReader init(got[3].fields);
      CHECK(init.Str() == std::optional<std::string>("/fw"));
      init.Str();
      init.Str();
      init.Str();
      CHECK(!init.Str().has_value());  // log_file NULL stays NULL
      CHECK(init.I32() == 0);
      init.Str();
      CHECK(!init.Str().has_value());
      CHECK(init.StrList() == std::vector<std::string>({"enable-logging", "v=1"}));
      CHECK(init.ok() && init.AtEnd());
      TlvReader tab(got[4].fields);
      CHECK(tab.I32() == cmux_remote::kFirstMintedBrowserID);  // the minted id goes first
      TlvReader window(got[6].fields);
      CHECK(window.I32() == cmux_remote::kFirstMintedBrowserID + 2);
      CHECK(window.I32() == 5);
    }
  }
  CHECK(!seen.scheduled);

  // The host's HELLO: ready, with the optional exports its shim defines.
  host.Send(Hello(cmux_remote::kWireID));
  CHECK(PumpUntil([] { return seen.ready == 1; }));
  CHECK(cmux_remote_shim_host_has_export("cmux_shim_tab_evaluate") == 1);
  CHECK(cmux_remote_shim_host_has_export("cmux_shim_tab_set_frozen") == 0);
  // The HELLO did not list tab_set_frozen: the queued one is refused, and the reload after it
  // goes; later calls fail at once, as a missing symbol would in process.
  {
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpReload);
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.unsupported == 1);
    CHECK(cmux_shim_tab_set_frozen(first, 0) == 0);
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.unsupported == 2);
    CHECK(stats.unsendable == 0);
  }

  // The verdict on the awaited preinit token reaches the reply callback once.
  {
    cmux_host::control::TlvWriter verdict;
    verdict.I32(1);
    Message reply;
    reply.op = cmux_remote::kOpReply;
    reply.token = scheme_token;
    reply.fields = verdict.Take();
    host.Send(reply);
    CHECK(PumpUntil([] { return !seen.replies.empty(); }));
    CHECK(seen.replies == std::vector<uint32_t>({scheme_token}));
  }

  // An async op returns at once; the token read right after it names its REPLY (task 018).
  {
    CHECK(cmux_shim_content_setting(cmux_remote::kFirstMintedBrowserID, "https://a.test/", "cookies") == 1);
    const uint32_t token = cmux_remote_shim_last_reply_token();
    CHECK(token != 0 && token != scheme_token);
    cmux_shim_reload(cmux_remote::kFirstMintedBrowserID);  // a post asks no answer: the token stays
    CHECK(cmux_remote_shim_last_reply_token() == token);
    const std::vector<Message> got = host.Read(2);
    CHECK(got.size() == 2 && got[0].op == cmux_remote::kOpContentSetting && got[0].token == token);
    cmux_host::control::TlvWriter setting;
    setting.I32(1);
    Message reply;
    reply.op = cmux_remote::kOpReply;
    reply.token = token;
    reply.fields = setting.Take();
    host.Send(reply);
    CHECK(PumpUntil([] { return seen.replies.size() == 2; }));
    CHECK(seen.replies == std::vector<uint32_t>({scheme_token, token}));

    // cmux_remote_shim_set_reply moves the replies to another sink and its ctx (CEFRemoteShim's).
    static std::vector<std::pair<void*, uint32_t>> sunk;
    int sink_ctx = 0;
    cmux_remote_shim_set_reply(&sink_ctx, [](void* ctx, uint32_t answered, const void*, size_t) {
      sunk.emplace_back(ctx, answered);
    });
    CHECK(cmux_shim_content_setting(cmux_remote::kFirstMintedBrowserID, "https://b.test/", "cookies") == 1);
    const uint32_t moved = cmux_remote_shim_last_reply_token();
    CHECK(moved != 0 && moved != token);
    const std::vector<Message> sent = host.Read(1);
    CHECK(sent.size() == 1 && sent[0].token == moved);
    reply.token = moved;
    host.Send(reply);
    CHECK(PumpUntil([] { return !sunk.empty(); }));
    CHECK(sunk.size() == 1 && sunk[0].first == &sink_ctx && sunk[0].second == moved);
    CHECK(seen.replies.size() == 2);
    cmux_remote_shim_set_reply(nullptr, &OnReply);
  }

  // A password reveal's REPLY goes to its own sink, never to the reply callback.
  {
    static std::vector<std::pair<uint32_t, std::string>> revealed;
    static bool null_password = false;
    const cmux_remote::PasswordRevealedFn sink = [](uint32_t answered, const char* password, size_t length) {
      null_password = password == nullptr;
      revealed.emplace_back(answered, password ? std::string(password, length) : std::string());
      return true;
    };
    CHECK(!cmux_remote::PostPasswordReveal(0, "/profile", "id1", sink));
    CHECK(!cmux_remote::PostPasswordReveal(cmux_remote::NextToken(), "/profile", "id1", nullptr));
    const uint32_t token = cmux_remote::NextToken();
    CHECK(cmux_remote::PostPasswordReveal(token, "/profile", "id1", sink));
    const std::vector<Message> sent = host.Read(1);
    CHECK(sent.size() == 1 && sent[0].op == cmux_remote::kOpPasswordReveal && sent[0].token == token);
    if (sent.size() == 1) {
      TlvReader request(sent[0].fields);
      CHECK(request.Str() == std::optional<std::string>("/profile"));
      CHECK(request.Str() == std::optional<std::string>("id1") && request.ok() && request.AtEnd());
    }
    cmux_host::control::TlvWriter password;
    password.Bytes("s3cret", 6);
    Message answer;
    answer.op = cmux_remote::kOpReply;
    answer.token = token;
    answer.fields = password.Take();
    host.Send(answer);
    CHECK(PumpUntil([] { return !revealed.empty(); }));
    CHECK(revealed.size() == 1 && revealed[0] == std::make_pair(token, std::string("s3cret")) && !null_password);
    CHECK(seen.replies.size() == 2);  // the reply callback never saw it

    const uint32_t missing = cmux_remote::NextToken();
    CHECK(cmux_remote::PostPasswordReveal(missing, "/profile", "id2", sink));
    CHECK(host.Read(1).size() == 1);
    Message none;
    none.op = cmux_remote::kOpReply;
    none.token = missing;
    host.Send(none);
    CHECK(PumpUntil([] { return revealed.size() == 2; }));
    CHECK(revealed.size() == 2 && revealed[1].first == missing && null_password);
    CHECK(seen.replies.size() == 2);
  }

  // A mirror value pushed before its EVENT is what the event's callback reads.
  const int browser = cmux_remote::kFirstMintedBrowserID;
  host.Send(Mirror(cmux_remote::kOpTabNavigationState, browser, "{\"index\":1}"));
  host.Send(Event(CMUX_SHIM_ADDRESS, browser));
  CHECK(PumpUntil([] { return seen.events == 1; }));
  CHECK(seen.state_in_event == "{\"index\":1}");
  CHECK(seen.s2.empty());  // a NULL string reaches the callback as ""

  // A resize fence carries this process's port name, which means nothing in the host: the
  // client refuses it as a fork without the call would and sends nothing, so the next frame
  // the host reads is go_back's.
  CHECK(cmux_shim_browser_set_resize_fence(browser, 0x1103u, 2) == 0);
  // An attach names an NSView of this process: refused the same way, nothing sent.
  int parent_view = 0;
  CHECK(cmux_shim_browser_attach_view(browser, &parent_view) == 0);

  // go_back marks the navigation state pending under its token until the host's ack.
  cmux_shim_go_back(browser);
  CHECK(NavigationState(browser) == "<null>");
  CHECK(NavigationState(browser + 1) == "<null>");  // never pushed
  {
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpGoBack && got[0].token != 0);
    if (!got.empty()) {
      Message ack;
      ack.op = cmux_remote::kOpAck;
      ack.token = got[0].token;
      host.Send(ack);
      CHECK(PumpUntil([&] { return NavigationState(browser) == "{\"index\":1}"; }));
    }
  }

  // The host's input acks reach the input ack callback, every record in the host's order; with
  // no callback they are counted.
  {
    const std::vector<InputAck> sent = {{browser, cmux_host::kMouse, 41}, {browser + 1, cmux_host::kWheel, 42},
                                        {browser, cmux_host::kWheel, 43}};
    host.Send(InputAckMessage(sent));
    CHECK(PumpUntil([] { return stats_unhandled_input_acks() == 3; }));
    cmux_remote_shim_set_input_ack(&input_ack_ctx, &OnInputAck);
    host.Send(InputAckMessage(sent));
    CHECK(PumpUntil([] { return input_acks.size() == 3; }));
    CHECK(input_acks == sent);
    CHECK(cmux_remote_shim_attached() == 1);
  }

  // An extension change is async with pending keys (task 026): the list is hidden until its
  // REPLY, and the reply callback reads the list the host pushed before it.
  {
    static std::string list_in_reply;
    static int ext_replies = 0;
    static int ext_browser = browser;
    host.Send(Mirror(cmux_remote::kOpExtList, browser, "[\"before\"]"));
    CHECK(PumpUntil([&] { return ExtensionList(browser) == "[\"before\"]"; }));
    cmux_remote_shim_set_reply(nullptr, [](void*, uint32_t, const void*, size_t) {
      list_in_reply = ExtensionList(ext_browser);
      ++ext_replies;
    });
    CHECK(cmux_shim_ext_set_enabled(browser, "abc", 0) == 1);
    const uint32_t token = cmux_remote_shim_last_reply_token();
    CHECK(token != 0);
    CHECK(ExtensionList(browser) == "<null>");
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpExtSetEnabled && got[0].token == token);
    host.Send(Mirror(cmux_remote::kOpExtList, browser, "[\"after\"]"));
    PumpUntil([] { return false; }, std::chrono::milliseconds(50));  // the MIRROR applies
    CHECK(ExtensionList(browser) == "<null>");  // still pending: the op has not answered
    cmux_host::control::TlvWriter verdict;
    verdict.I32(0);
    Message reply;
    reply.op = cmux_remote::kOpReply;
    reply.token = token;
    reply.fields = verdict.Take();
    host.Send(reply);
    CHECK(PumpUntil([] { return ext_replies == 1; }));
    CHECK(list_in_reply == "[\"after\"]");
    cmux_remote_shim_set_reply(nullptr, &OnReply);
  }

  // Settings changes after initialize go now, and into the replay log for the next host.
  cmux_shim_set_new_tab_page_url("cmux-page://latest/");
  cmux_shim_set_background_color(0xff445566u);
  CHECK(cmux_shim_page_scheme_add("later", "/tmp", nullptr) == 1);
  {
    const std::vector<Message> got = host.Read(3);
    CHECK(got.size() == 3);
    if (got.size() == 3) {
      CHECK(got[0].op == cmux_remote::kOpSetNewTabPageUrl && got[0].token == 0);
      CHECK(got[1].op == cmux_remote::kOpSetBackgroundColor && got[1].token == 0);
      CHECK(got[2].op == cmux_remote::kOpPageSchemeAdd && got[2].token != 0);
    }
  }

  // One ordered input stream (task 092): an ordered op (focus, activation) carries its control
  // seq and the input seq written before it; an input frame names the last ordered op; other
  // ops carry neither.
  {
    uint32_t ctl = 99;
    CHECK(cmux_remote_shim_order_input(&ctl) == 1 && ctl == 0);
    cmux_shim_set_focus(browser, 1);
    cmux_shim_reload(browser);
    CHECK(cmux_remote_shim_order_input(&ctl) == 2 && ctl == 1);
    CHECK(cmux_remote_shim_order_input(&ctl) == 3 && ctl == 1);
    CHECK(cmux_shim_tab_activate(browser + 1) == 1);
    const std::vector<Message> got = host.Read(3);
    CHECK(got.size() == 3);
    if (got.size() == 3) {
      CHECK(got[0].op == cmux_remote::kOpSetFocus && got[0].ctl_seq == 1 && got[0].after_input == 1);
      CHECK(got[1].op == cmux_remote::kOpReload && got[1].ctl_seq == 0 && got[1].after_input == 0);
      CHECK(got[2].op == cmux_remote::kOpTabActivate && got[2].ctl_seq == 2 && got[2].after_input == 3);
    }
  }

  // The page's IME ops are ordered too: a commit is applied after the key frame
  // written before it, never ahead of it.
  {
    uint32_t ctl = 0;
    const uint8_t text[] = {0xe5, 0x65, 0x2c, 0x67};  // "日本" as UTF-16LE
    const uint8_t clause[] = {0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0xff, 1, 0, 0, 0};
    CHECK(cmux_remote_shim_order_input(&ctl) == 4 && ctl == 2);
    cmux_shim_browser_ime_set_composition(browser, text, sizeof text, clause, sizeof clause, 2, 2, -1, -1);
    cmux_shim_browser_ime_commit_text(browser, text, sizeof text, -1, -1);
    CHECK(cmux_remote_shim_order_input(&ctl) == 5 && ctl == 4);
    cmux_shim_browser_ime_finish_composing(browser);
    cmux_shim_browser_ime_cancel_composition(browser);
    const std::vector<Message> got = host.Read(4);
    CHECK(got.size() == 4);
    if (got.size() == 4) {
      CHECK(got[0].op == cmux_remote::kOpBrowserImeSetComposition && got[0].ctl_seq == 3 && got[0].after_input == 4);
      CHECK(got[0].fields.size() == 7 && got[0].fields[1].bytes == std::string("\xe5\x65\x2c\x67", 4));
      CHECK(got[1].op == cmux_remote::kOpBrowserImeCommitText && got[1].ctl_seq == 4 && got[1].after_input == 4);
      CHECK(got[2].op == cmux_remote::kOpBrowserImeFinishComposing && got[2].ctl_seq == 5 && got[2].after_input == 5);
      CHECK(got[3].op == cmux_remote::kOpBrowserImeCancelComposition && got[3].ctl_seq == 6 && got[3].after_input == 5);
    }
  }

  // A page resize (task 052) is an ordered op too. With no fence channel (and no Mach off macOS)
  // it goes unfenced: fence seq 0, no token, nothing to answer.
  {
    CHECK(cmux_remote_shim_set_resize_fence_channel(0) == 1);
    CHECK(cmux_remote_shim_page_resize(9, browser, 640, 480, 0x1103u, 1) == CMUX_REMOTE_RESIZE_UNFENCED);
    CHECK(cmux_remote_shim_last_reply_token() == 0);
    CHECK(cmux_remote_shim_page_resize(0, browser, 640, 480, 0, 1) == CMUX_REMOTE_RESIZE_NOT_SENT);  // no view
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_host::kOpPageResize && got[0].token == 0 && got[0].ctl_seq == 7 &&
          got[0].after_input == 5);
    const std::optional<cmux_host::PageResize> resize =
        got.empty() ? std::nullopt : cmux_host::DecodePageResize(got[0].fields);
    CHECK(resize && resize->view == 9 && resize->browser == browser && resize->width == 640 &&
          resize->height == 480 && resize->fence_seq == 0 && resize->deadline_frames == 1);
  }

  // With a fence channel, the fence right goes to the host's inbox first, under the next fence
  // seq, and the op carries that seq and a token the host answers. A fence the inbox did not take
  // sends the op unfenced and takes no seq.
  {
    cmux_remote_shim_set_fence_sender(&RecordFenceSend);
    CHECK(cmux_remote_shim_set_resize_fence_channel(0x2201u) == 1);
    CHECK(cmux_remote_shim_page_resize(9, browser, 700, 480, 0x1103u, 1) == CMUX_REMOTE_RESIZE_FENCED);
    const uint32_t first = cmux_remote_shim_last_reply_token();
    CHECK(first != 0);
    CHECK(cmux_remote_shim_page_resize(9, browser, 720, 480, 0x1104u, 1) == CMUX_REMOTE_RESIZE_FENCED);
    const uint32_t second = cmux_remote_shim_last_reply_token();
    CHECK(second != 0 && second != first);
    fence_send_result = 0;
    CHECK(cmux_remote_shim_page_resize(9, browser, 740, 480, 0x1105u, 1) == CMUX_REMOTE_RESIZE_UNFENCED);
    CHECK(cmux_remote_shim_last_reply_token() == 0);
    fence_send_result = 1;
    CHECK(cmux_remote_shim_page_resize(9, browser, 760, 480, 0, 1) == CMUX_REMOTE_RESIZE_UNFENCED);  // no fence
    CHECK(cmux_remote_shim_page_resize(9, browser, 780, 480, 0x1106u, 1) == CMUX_REMOTE_RESIZE_FENCED);
    const uint32_t third = cmux_remote_shim_last_reply_token();
    CHECK(fence_sends.size() == 4);
    if (fence_sends.size() == 4) {
      CHECK(fence_sends[0].channel == 0x2201u && fence_sends[0].fence == 0x1103u && fence_sends[0].seq == 1);
      CHECK(fence_sends[1].fence == 0x1104u && fence_sends[1].seq == 2);
      CHECK(fence_sends[2].fence == 0x1105u && fence_sends[2].seq == 3);  // not taken
      CHECK(fence_sends[3].fence == 0x1106u && fence_sends[3].seq == 3);  // the seq the failed one did not take
    }
    const std::vector<Message> got = host.Read(5);
    CHECK(got.size() == 5);
    const uint64_t seqs[] = {1, 2, 0, 0, 3};
    const uint32_t tokens[] = {first, second, 0, 0, third};
    for (size_t i = 0; i < got.size() && i < 5; ++i) {
      const std::optional<cmux_host::PageResize> resize = cmux_host::DecodePageResize(got[i].fields);
      CHECK(got[i].op == cmux_host::kOpPageResize && got[i].token == tokens[i] && got[i].ctl_seq != 0);
      CHECK(resize && resize->view == 9 && resize->width == 700 + 20 * static_cast<int32_t>(i) &&
            resize->fence_seq == seqs[i]);
    }
    cmux_remote_shim_set_fence_sender(nullptr);
    CHECK(cmux_remote_shim_set_resize_fence_channel(0) == 1);
  }

  // A host that never reads: posts still return at once, and the geometry of a page waits
  // coalesced to one frame.
  cmux_remote_shim_get_stats(&stats);
  const uint64_t coalesced = stats.coalesced;
  const auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < 20000; ++i) cmux_shim_set_zoom_level(browser, 1.0);
  CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.coalesced > coalesced);
  CHECK(stats.pending_messages >= 1 && stats.pending_messages <= 2);  // one waiting, one maybe half written
  {
    // Input on the control channel is a coalescing boundary: with the socket full, a placement,
    // a wheel and a placement reach the host as three messages in that order; a third placement
    // with no input since replaces the second.
    cmux_remote_shim_get_stats(&stats);
    const uint64_t before = stats.coalesced;
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 100, 10);
    CHECK(cmux_shim_browser_send_wheel(browser, 100, 1, 0, 5, 1, 2, 0, 0) == 1);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 200, 10);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 300, 10);
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.coalesced == before + 1);
    std::vector<std::string> got;
    ReadThrough(&host, [&](const Message& m) {
      if (m.op == cmux_remote::kOpDevtoolsSetPlacement) got.push_back("p" + std::to_string(m.fields.at(4).integer));
      if (m.op == cmux_remote::kOpBrowserSendWheel) got.push_back("w");
      return got.size() == 3;
    });
    CHECK(got == std::vector<std::string>({"p100", "w", "p300"}));
  }

  // A second reply to the same token answers no request: it ends the host.
  Message again;
  again.op = cmux_remote::kOpReply;
  again.token = scheme_token;
  host.Send(again);
  CHECK(PumpUntil([] { return seen.ended >= 0; }));
  CHECK(seen.ended == CMUX_REMOTE_END_MALFORMED);
  CHECK(cmux_remote_shim_attached() == 0);
  CHECK(NavigationState(browser) == "<null>");  // the cache went with the host
  cmux_remote_shim_get_stats(&stats);
  const uint64_t unsendable = stats.unsendable;
  cmux_shim_load_url(browser, "https://d.test/");
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.unsendable == unsendable + 1);
  ::close(host.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));  // the old channel's end, dropped

  // With no host, a settings change is kept for the next one, and a new scheme asks its verdict
  // there.
  cmux_shim_set_background_color(0xff778899u);
  CHECK(cmux_shim_page_scheme_add("gone", "/tmp", nullptr) == 1);

  // A restarted host gets HELLO, the replay log with the latest values (each verdict asked
  // once) and INITIALIZE, then new posts.
  cmux_shim_set_focus(browser, 0);  // detached: dropped, and takes no control seq
  {
    // Detached: the ring writer writes no frame, so no input seq waits for the next host.
    uint32_t ctl = 99;
    CHECK(cmux_remote_shim_order_input(&ctl) == 0 && ctl == 0);
  }
  Host second;
  CHECK(AttachNew(&second) == 1);
  cmux_shim_set_focus(browser, 1);  // the new host's first ordered op follows no input
  cmux_shim_stop(browser);
  {
    const std::vector<uint16_t> want = {cmux_host::control::kOpHello,     cmux_remote::kOpSetBackgroundColor,
                                        cmux_remote::kOpPageSchemeAdd,    cmux_remote::kOpSetNewTabPageUrl,
                                        cmux_remote::kOpPageSchemeAdd,    cmux_remote::kOpPageSchemeAdd,
                                        cmux_remote::kOpInitialize,       cmux_remote::kOpSetFocus,
                                        cmux_remote::kOpStop};
    const std::vector<Message> got = second.Read(want.size());
    CHECK(got.size() == want.size());
    for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK(got[i].op == want[i]);
    if (got.size() == want.size()) {
      TlvReader color(got[1].fields);
      CHECK(color.U32() == 0xff778899u);
      CHECK(got[2].token == 0);
      TlvReader docs(got[2].fields);
      CHECK(docs.Str() == std::optional<std::string>("docs"));
      TlvReader url(got[3].fields);
      CHECK(url.Str() == std::optional<std::string>("cmux-page://latest/"));
      TlvReader later(got[4].fields);
      CHECK(later.Str() == std::optional<std::string>("later") && got[4].token == 0);
      TlvReader gone(got[5].fields);
      CHECK(gone.Str() == std::optional<std::string>("gone") && got[5].token != 0);
      // The focus posted while detached took no seq: the new host's first ordered op is seq 1,
      // after no input.
      CHECK(got[7].ctl_seq == 1 && got[7].after_input == 0);
    }
  }
  {
    // A new host has a new ring and ordered stream: both seqs start again.
    uint32_t ctl = 99;
    CHECK(cmux_remote_shim_order_input(&ctl) == 1 && ctl == 1);
    cmux_shim_set_focus(browser, 0);
    const std::vector<Message> got = second.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpSetFocus && got[0].ctl_seq == 2 &&
          got[0].after_input == 1);
  }
  // Its HELLO from another generation of the op table ends it. cmux_remote_shim_set_ended moves
  // the end to another sink and its ctx (CEFRemoteShim's, task 091).
  seen.ended = -1;
  {
    static std::vector<std::pair<void*, int>> ends;
    int end_ctx = 0;
    cmux_remote_shim_set_ended(&end_ctx, [](void* ctx, int reason) { ends.emplace_back(ctx, reason); });
    second.Send(Hello("another-wire"));
    CHECK(PumpUntil([] { return !ends.empty(); }));
    CHECK(ends.size() == 1 && ends[0].first == &end_ctx && ends[0].second == CMUX_REMOTE_END_MALFORMED);
    CHECK(seen.ended == -1);
    CHECK(cmux_remote_shim_attached() == 0);
    cmux_remote_shim_set_ended(nullptr, &OnEnded);
  }
  CHECK(seen.ready == 1);
  ::close(second.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));

  // A detach cmux asks for is not reported back. Before it, the attach queue (an optional op
  // waits for the HELLO) keeps a state op across input: a placement before a ring frame or a
  // control-channel wheel is not replaced by one after it.
  Host third;
  CHECK(AttachNew(&third) == 1);
  {
    cmux_remote_shim_get_stats(&stats);
    const uint64_t before = stats.coalesced;
    CHECK(cmux_shim_tab_set_frozen(browser, 1) == 1);  // queued until the HELLO
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 10, 10);
    uint32_t ctl = 0;
    CHECK(cmux_remote_shim_order_input(&ctl) == 1 && ctl == 1);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 20, 10);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 30, 10);  // replaces 20
    CHECK(cmux_shim_browser_send_wheel(browser, 30, 1, 0, 5, 1, 2, 0, 0) == 1);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 40, 10);
    cmux_shim_devtools_set_placement(browser, nullptr, 0, 0, 50, 10);  // replaces 40
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.coalesced == before + 2);
    const int ready = seen.ready;
    third.Send(Hello(cmux_remote::kWireID));
    CHECK(PumpUntil([&] { return seen.ready == ready + 1; }));
    std::vector<Message> got;
    ReadThrough(&third, [&](const Message& m) {
      if (m.op == cmux_remote::kOpDevtoolsSetPlacement || m.op == cmux_remote::kOpBrowserSendWheel) got.push_back(m);
      return got.size() == 4;
    });
    CHECK(got.size() == 4);
    if (got.size() == 4) {
      CHECK(got[0].op == cmux_remote::kOpDevtoolsSetPlacement && got[0].fields.at(4).integer == 10 &&
            got[0].ctl_seq == 1 && got[0].after_input == 0);
      CHECK(got[1].op == cmux_remote::kOpDevtoolsSetPlacement && got[1].fields.at(4).integer == 30 &&
            got[1].ctl_seq == 3 && got[1].after_input == 1);
      CHECK(got[2].op == cmux_remote::kOpBrowserSendWheel);
      CHECK(got[3].op == cmux_remote::kOpDevtoolsSetPlacement && got[3].fields.at(4).integer == 50 &&
            got[3].ctl_seq == 5 && got[3].after_input == 1);
    }
  }
  seen.ended = -1;
  cmux_remote_shim_detach();
  CHECK(cmux_remote_shim_attached() == 0);
  // With no host a fence channel would name a host that is gone, and a resize goes nowhere.
  CHECK(cmux_remote_shim_set_resize_fence_channel(0) == 0);
  CHECK(cmux_remote_shim_page_resize(9, 1, 640, 480, 0x1103u, 1) == CMUX_REMOTE_RESIZE_NOT_SENT);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
  CHECK(seen.ended == -1);
  ::close(third.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));

  // A reveal no answer reaches ends once as not found, revealed(token, NULL, 0): a detach, the
  // host's exit, a malformed answer, a queued op that was then not sent.
  {
    static std::vector<std::pair<uint32_t, bool>> ended;  // token, and whether password was NULL
    const cmux_remote::PasswordRevealedFn sink = [](uint32_t token, const char* password, size_t) {
      ended.emplace_back(token, password == nullptr);
      return true;
    };
    // Reads an attach's frames up to the first reveal; true when it is `token`'s.
    const auto read_reveal = [](Host& h, uint32_t token) {
      for (int i = 0; i < 64; ++i) {
        const std::vector<Message> got = h.Read(1);
        if (got.empty()) return false;
        if (got[0].op == cmux_remote::kOpPasswordReveal) return got[0].token == token;
      }
      return false;
    };
    const auto ended_once = [](uint32_t token) { return ended == std::vector<std::pair<uint32_t, bool>>{{token, true}}; };
    const auto answer = [](Host& h, uint32_t token, const cmux_host::control::TlvWriter& fields) {
      Message reply;
      reply.op = cmux_remote::kOpReply;
      reply.token = token;
      reply.fields = fields.fields();
      h.Send(reply);
    };
    const auto settle = [](Host& h) {
      ::close(h.fd);
      PumpUntil([] { return false; }, std::chrono::milliseconds(100));  // the old channel's end
    };

    // A detach cmux asks for.
    {
      Host h;
      CHECK(AttachNew(&h) == 1);
      const uint32_t token = cmux_remote::NextToken();
      CHECK(cmux_remote::PostPasswordReveal(token, "/profile", "id", sink));
      CHECK(read_reveal(h, token));
      CHECK(ended.empty());
      cmux_remote_shim_detach();
      CHECK(ended_once(token));
      settle(h);
      CHECK(ended_once(token));  // never twice
      ended.clear();
    }
    // The host's exit.
    {
      Host h;
      CHECK(AttachNew(&h) == 1);
      const uint32_t token = cmux_remote::NextToken();
      CHECK(cmux_remote::PostPasswordReveal(token, "/profile", "id", sink));
      CHECK(read_reveal(h, token));
      seen.ended = -1;
      ::close(h.fd);
      CHECK(PumpUntil([] { return seen.ended >= 0; }));
      CHECK(ended_once(token));
      ended.clear();
    }
    // A malformed answer ends the host, and the reveal with it: two fields, or a field of
    // another type.
    for (int shape = 0; shape < 2; ++shape) {
      Host h;
      CHECK(AttachNew(&h) == 1);
      const uint32_t token = cmux_remote::NextToken();
      CHECK(cmux_remote::PostPasswordReveal(token, "/profile", "id", sink));
      CHECK(read_reveal(h, token));
      cmux_host::control::TlvWriter fields;
      if (shape == 0) {
        fields.Bytes("a", 1);
        fields.Bytes("b", 1);
      } else {
        fields.I32(7);
      }
      seen.ended = -1;
      answer(h, token, fields);
      CHECK(PumpUntil([] { return seen.ended >= 0; }));
      CHECK(seen.ended == CMUX_REMOTE_END_MALFORMED);
      CHECK(ended_once(token));
      ended.clear();
      settle(h);
    }
    // Queued behind an optional op before the HELLO, then a detach.
    {
      Host h;
      CHECK(AttachNew(&h) == 1);
      CHECK(cmux_shim_tab_set_frozen(first, 1) == 1);  // waits for the HELLO
      const uint32_t token = cmux_remote::NextToken();
      CHECK(cmux_remote::PostPasswordReveal(token, "/profile", "id", sink));
      cmux_remote_shim_detach();
      CHECK(ended_once(token));
      ended.clear();
      settle(h);
    }
    // Queued before the HELLO, then not sendable when the HELLO flushes the queue (shared fields
    // over kMaxSharedBytes): its true stands, and it ends as not found. Sent at once and refused,
    // it is false and the sink never runs.
    {
      const std::string huge(cmux_host::control::kMaxSharedBytes + 1, 'p');
      Host h;
      CHECK(AttachNew(&h) == 1);
      CHECK(cmux_shim_tab_set_frozen(first, 1) == 1);
      const uint32_t token = cmux_remote::NextToken();
      CHECK(cmux_remote::PostPasswordReveal(token, huge.c_str(), "id", sink));
      CHECK(ended.empty());
      h.Send(Hello(cmux_remote::kWireID));
      CHECK(PumpUntil([] { return !ended.empty(); }));
      CHECK(ended_once(token));
      ended.clear();
      CHECK(!cmux_remote::PostPasswordReveal(cmux_remote::NextToken(), huge.c_str(), "id", sink));
      cmux_remote_shim_detach();
      CHECK(ended.empty());
      settle(h);
    }
  }

  // An input ack of a kind cmux does not pace, an empty one or a cut record is malformed: it ends
  // the host, and no record of it reaches the callback.
  std::vector<Field> cut = InputAckMessage({{browser, cmux_host::kWheel, 52}}).fields;
  cut.pop_back();
  for (const std::vector<Field>& fields : {
           InputAckMessage({{browser, cmux_host::kMouse, 50}, {browser, cmux_host::kKey, 51}}).fields,
           std::vector<Field>(), cut}) {
    Host bad;
    CHECK(AttachNew(&bad) == 1);
    bad.Read(1);  // HELLO
    seen.ended = -1;
    input_acks.clear();
    Message ack;
    ack.op = cmux_host::control::kOpInputAck;
    ack.fields = fields;
    bad.Send(ack);
    CHECK(PumpUntil([] { return seen.ended >= 0; }));
    CHECK(seen.ended == CMUX_REMOTE_END_MALFORMED);
    CHECK(input_acks.empty());
    ::close(bad.fd);
    PumpUntil([] { return false; }, std::chrono::milliseconds(50));
  }
  cmux_remote_shim_set_input_ack(nullptr, nullptr);

  TestOrderingThroughTheRuntime();
  TestEnergySaver();
  TestProviderLink();
  TestHostWatch();
  TestLocks();

  // View tokens: cmux passes the page view's token where the ABI takes a parent NSView*, and it
  // travels as is (never a pointer the client reads); NULL is 0.
  {
    cmux_remote::TlvWriter w;
    w.View(nullptr);
    w.View(reinterpret_cast<void*>(uintptr_t{7}));
    w.View(reinterpret_cast<void*>(uintptr_t{7}));
    CHECK(w.fields().size() == 3);
    if (w.fields().size() == 3) {
      CHECK(w.fields()[0].integer == 0);
      CHECK(w.fields()[1].integer == 7 && w.fields()[2].integer == 7);
    }
  }

  if (failures == 0) std::printf("remote shim: ok\n");
  return failures == 0 ? 0 : 1;
}
