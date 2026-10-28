// One ordered input stream (chromium_host_wire.h, "One
// ordered input stream"): the ordered frame's order word, the outbox keeping
// a state op that input was written after, the ring queue never folding input
// across a control seq, the OrderedStream's two checks, and the ordering case:
// 10,000 keys interleaved with focus changes, IME commits and resizes across 2
// pages, the control messages through a real control::Outbox and the two
// streams arriving in random interleavings, land on the active page in send
// order. The same delivery with no barrier must misroute keys, so the case
// fails without the fix. remote_shim_test.cpp runs the same case through the
// remote shim's runtime, its channel and the host's FrameQueue.
// Built and run by scripts/cmux-next/tests/chromium-host-wire.test.sh.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <optional>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "../src/chromium_host_control.h"

namespace control = cmux_host::control;
using cmux_host::Header;
using Result = control::OrderedStream::Result;

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

static std::string HexOf(const std::vector<uint8_t>& bytes) {
  static const char kDigits[] = "0123456789abcdef";
  std::string out;
  for (uint8_t b : bytes) {
    out.push_back(kDigits[b >> 4]);
    out.push_back(kDigits[b & 15]);
  }
  return out;
}

static control::Message Control(uint16_t op, uint32_t ctl_seq, uint32_t after_input, int32_t value = 0) {
  control::Message m;
  m.op = op;
  m.ctl_seq = ctl_seq;
  m.after_input = after_input;
  m.fields = {control::Field::I32(0, value)};
  return m;
}

static Header Input(uint32_t seq, uint32_t ctl_seq, int32_t value = 0) {
  Header h;
  h.kind = cmux_host::kKey;
  h.seq = seq;
  h.v[1] = value;
  cmux_host::SetCtlSeq(&h, ctl_seq);
  return h;
}

static void TestSeqHelpers() {
  Check(cmux_host::NextSeq(0) == 1 && cmux_host::NextSeq(7) == 8, "NextSeq counts");
  Check(cmux_host::NextSeq(UINT32_MAX) == 1, "NextSeq skips 0 when it wraps");
  Check(cmux_host::SeqAtOrBefore(3, 3) && cmux_host::SeqAtOrBefore(3, 4) && !cmux_host::SeqAtOrBefore(4, 3),
        "SeqAtOrBefore orders");
  Check(cmux_host::SeqAtOrBefore(UINT32_MAX, 1), "SeqAtOrBefore holds across a wrap");
  Header h;
  h.t1 = 0x1234;  // the page (task 041) stays in the low 32 bits
  cmux_host::SetCtlSeq(&h, 0xabcdef01u);
  Check(cmux_host::CtlSeqOf(h) == 0xabcdef01u && (h.t1 & 0xffffffffu) == 0x1234, "ctl_seq in t1's high bits");
}

static void TestOrderedFrame() {
  control::Message m = Control(0x10, 5, 3, 9);
  m.token = 7;
  std::vector<uint8_t> bytes;
  Check(control::Encode(m, &bytes), "an ordered message encodes");
  // len 8 | op 0x10 | flags kFlagOrdered | token 7 | ctl_seq 5 | after_input 3 | i32 field 9
  Check(HexOf(bytes) == "08000000100010000700000005000000030000000100040009000000", "the ordered golden frame");
  std::deque<int> fds;
  control::Message out;
  size_t used = 0;
  Check(control::Decode(bytes.data(), bytes.size(), &fds, &out, &used) == control::Parse::kFrame &&
            used == bytes.size() && out.ctl_seq == 5 && out.after_input == 3 && out.token == 7 &&
            out.fields == m.fields,
        "an ordered frame decodes with its order word");
  Check(control::Decode(bytes.data(), control::kHeaderSize + 4, &fds, &out, &used) == control::Parse::kNeedMore,
        "half an order word needs more");
  std::vector<uint8_t> zero = bytes;
  std::memset(zero.data() + control::kHeaderSize, 0, 4);
  Check(control::Decode(zero.data(), zero.size(), &fds, &out, &used) == control::Parse::kMalformed,
        "an ordered frame with control seq 0 is malformed");

  control::Message plain = Control(0x10, 0, 0, 9);
  std::vector<uint8_t> plain_bytes;
  Check(control::Encode(plain, &plain_bytes) && plain_bytes.size() + control::kOrderSize == bytes.size() &&
            plain_bytes[6] == 0,
        "an unordered message has no order word and no flag");
  control::Message barrier_only = Control(0x10, 0, 4);
  std::vector<uint8_t> refused;
  Check(!control::Encode(barrier_only, &refused) && refused.empty(), "an input barrier with no control seq is refused");
}

// The host's ring queue folds moves, wheels and geometry only within one
// control seq and one page: a wheel must still meet the state it was written
// against.
static void TestFrameQueueKeepsInputAcrossControl() {
  cmux_host::FrameQueue queue(16);
  queue.MarkReady();
  auto wheel = [](uint32_t seq, uint32_t ctl_seq, uint32_t page, int32_t dy) {
    Header h;
    h.kind = cmux_host::kWheel;
    h.seq = seq;
    h.v[3] = dy;
    h.t1 = page;
    cmux_host::SetCtlSeq(&h, ctl_seq);
    return h;
  };
  queue.Add(wheel(1, 0, 1, 3), {});
  queue.Add(wheel(2, 0, 1, 4), {});
  Check(queue.size() == 1 && queue.coalesced() == 1, "two wheels with one control seq fold");
  queue.Add(wheel(3, 1, 1, 5), {});  // an ordered op (control seq 1) came between
  Check(queue.size() == 2, "wheel, ordered op, wheel stay two frames");
  queue.Add(wheel(4, 1, 2, 6), {});
  Check(queue.size() == 3, "a wheel for another page is its own frame");
  Header geometry;
  geometry.kind = cmux_host::kGeometry;
  geometry.seq = 5;
  queue.Add(geometry, {});
  geometry.seq = 6;
  cmux_host::SetCtlSeq(&geometry, 2);
  queue.Add(geometry, {});
  Check(queue.size() == 5, "geometry across a control seq stays two frames");
  const std::deque<cmux_host::QueuedFrame> taken = queue.Take();
  Check(taken.size() == 5 && taken[0].header.v[3] == 7 && taken[0].header.seq == 2 && taken[1].header.v[3] == 5 &&
            cmux_host::CtlSeqOf(taken[1].header) == 1,
        "the folded wheel sums its run's deltas; the next keeps its own");
}

// Ring frames that are not input (kPing, kStats: `seq` is a request id) keep
// their place in the ring and are never checked as input seqs.
static void TestStreamPassesNonInputKinds() {
  std::vector<std::string> log;
  control::OrderedStream stream([&log](std::vector<control::Message> run) {
    for (const control::Message& m : run) log.push_back("c" + std::to_string(m.fields.at(0).integer));
  });
  stream.AttachInput([&log](const Header& h) { log.push_back(std::to_string(h.kind) + ":" + std::to_string(h.seq)); });
  stream.OpenInput();
  Header ping;
  ping.kind = cmux_host::kPing;
  ping.seq = 0;
  Check(stream.AddInput(ping) == Result::kOk, "a ping with seq 0 is not malformed");
  Header stats;
  stats.kind = cmux_host::kStats;
  stats.seq = 7;  // its request id
  Check(stream.AddInput(stats) == Result::kOk && stream.AddInput(stats) == Result::kOk,
        "a repeated stats request id is not malformed");
  Check(stream.AddInput(Input(1, 1, 1)) == Result::kOk, "input 1 waits for control 1");
  stats.seq = 3;
  Check(stream.AddInput(stats) == Result::kOk, "a stats request behind it waits in ring order");
  Check(stream.AddControl({Control(1, 1, 0, 1)}) == Result::kOk, "control 1");
  Check(log == std::vector<std::string>({"7:0", "8:7", "8:7", "c1", "5:1", "8:3"}),
        "non-input kinds go in ring order with no seq check");
  Check(stream.dispatched_input() == 1, "only input seqs count as dispatched");
  Check(stream.AddInput(Input(1, 0)) == Result::kMalformed, "an input kind still needs a new seq");
}

static void TestOutboxKeepsStateAcrossInput() {
  control::Outbox outbox(1 << 20, 1 << 20);
  const uint64_t key = control::StateKey(58, 1);
  Check(!outbox.Push({1}, {}, key, 0, 1), "first geometry");
  Check(outbox.Push({2}, {}, key, 0, 1), "a geometry with no input between replaces the waiting one");
  Check(outbox.CountKey(key) == 1, "one geometry waits");
  Check(!outbox.Push({3}, {}, key, 0, 2), "a geometry after an input does not replace the one before it");
  Check(outbox.CountKey(key) == 2 && outbox.messages() == 2, "both geometries wait: the input meets the older one");
  Check(outbox.Push({4}, {}, key, 0, 2), "the newest of the second run replaces its run's waiting one");
  Check(outbox.CountKey(key) == 2, "still one per input boundary");
}

// The stream with a log of what it handed on: "c<value>" applied, "i<value>" dispatched.
struct Logged {
  std::vector<std::string> log;
  size_t applies = 0;
  control::OrderedStream stream;

  explicit Logged(control::OrderedStream::Limits limits = {})
      : stream(
            [this](std::vector<control::Message> run) {
              ++applies;
              for (const control::Message& m : run) log.push_back("c" + std::to_string(m.fields.at(0).integer));
            },
            limits) {
    stream.AttachInput([this](const Header& h) { log.push_back("i" + std::to_string(h.v[1])); });
  }
};

static void TestStreamChecks() {
  {
    Logged t;
    Check(t.stream.OpenInput() == Result::kOk, "open");
    Check(t.stream.AddInput(Input(1, 1, 1)) == Result::kOk && t.log.empty(), "input waits for the control it names");
    Check(t.stream.AddControl({Control(1, 1, 0, 1)}) == Result::kOk, "control arrives");
    Check(t.log == std::vector<std::string>({"c1", "i1"}), "the control, then the input");
  }
  {
    Logged t;
    t.stream.OpenInput();
    Check(t.stream.AddControl({Control(1, 1, 2, 1), Control(2, 0, 0, 2)}) == Result::kOk && t.log.empty(),
          "a control waits for the input it follows, and the unordered one behind it keeps its place");
    t.stream.AddInput(Input(1, 0, 1));
    Check(t.log == std::vector<std::string>({"i1"}), "input 1 goes; the control still waits for input 2");
    t.stream.AddInput(Input(2, 0, 2));
    Check(t.log == std::vector<std::string>({"i1", "i2", "c1", "c2"}), "input 2, then both controls");
    Check(t.stream.applied_control() == 1 && t.stream.dispatched_input() == 2, "applied and dispatched seqs");
  }
  {
    // Controls 3 and 4 never come (replaced in the outbox): control 5 first in line settles them.
    Logged t;
    t.stream.OpenInput();
    t.stream.AddInput(Input(1, 3, 1));
    Check(t.log.empty(), "input naming control 3 waits");
    t.stream.AddControl({Control(1, 5, 1, 5)});
    Check(t.log == std::vector<std::string>({"i1", "c5"}), "a later control settles the missing one; input first");
  }
  {
    // Inputs 2 and 3 never come (coalesced in cmux): input 4 first in line settles them.
    Logged t;
    t.stream.OpenInput();
    t.stream.AddInput(Input(1, 0, 1));
    t.stream.AddControl({Control(1, 1, 3, 1)});
    Check(t.log == std::vector<std::string>({"i1"}), "control waits for input 3");
    t.stream.AddInput(Input(4, 1, 4));
    Check(t.log == std::vector<std::string>({"i1", "c1", "i4"}), "input 4 settles 3: control, then input 4");
  }
  {
    Logged t;
    t.stream.OpenInput();
    t.stream.AddInput(Input(1, 1, 1));
    t.stream.AddControl({Control(control::kOpSeqMark, 1, 0, 99)});
    Check(t.log == std::vector<std::string>({"i1"}), "a seq mark settles its seq and is not applied");
  }
  {
    Logged t;
    t.stream.AddControl({Control(1, 0, 0, 1)});
    t.stream.AddInput(Input(1, 0, 1));
    Check(t.log == std::vector<std::string>({"c1"}), "input waits for OpenInput; controls do not");
    t.stream.OpenInput();
    Check(t.log == std::vector<std::string>({"c1", "i1"}), "OpenInput dispatches");
  }
  {
    Logged t;
    t.stream.AddControl({Control(1, 0, 0, 1), Control(2, 1, 0, 2), Control(3, 0, 0, 3)});
    Check(t.applies == 1 && t.log.size() == 3, "a ready run is applied in one call");
  }
  {
    Logged t;
    t.stream.OpenInput();
    t.stream.AddInput(Input(2, 2, 2));
    Check(t.stream.AddControl({Control(1, 2, 2, 2)}) == Result::kMalformed && t.stream.what() != nullptr,
          "a control and an input each sent after the other is malformed");
    Check(t.stream.AddInput(Input(3, 0)) == Result::kMalformed, "a malformed stream stays malformed");
  }
  {
    Logged t;
    t.stream.AddControl({Control(1, 4, 0, 1)});
    Check(t.stream.AddControl({Control(1, 4, 0, 1)}) == Result::kMalformed, "a repeated control seq is malformed");
  }
  {
    Logged t;
    t.stream.AddInput(Input(5, 0));
    Check(t.stream.AddInput(Input(5, 0)) == Result::kMalformed, "a repeated input seq is malformed");
    Logged u;
    Check(u.stream.AddInput(Input(0, 0)) == Result::kMalformed, "input seq 0 is malformed");
  }
  {
    Logged t({2, 64});
    Check(t.stream.AddInput(Input(1, 0)) == Result::kOk && t.stream.AddInput(Input(2, 0)) == Result::kOk,
          "two inputs held");
    Check(t.stream.AddInput(Input(3, 0)) == Result::kFull && t.stream.held_input() == 2,
          "past the held-input limit the ring keeps the frame");
    t.stream.OpenInput();
    Check(t.stream.AddInput(Input(3, 0)) == Result::kOk && t.stream.held_input() == 0, "taken again once drained");
  }
  {
    Logged t({16, 2});
    t.stream.OpenInput();
    Check(t.stream.AddControl({Control(1, 1, 5), Control(1, 2, 5), Control(1, 3, 5)}) == Result::kMalformed,
          "controls past the limit waiting for input that never came are malformed");
  }
  {
    control::OrderedStream stream([](std::vector<control::Message>) {});
    Check(stream.AddInput(Input(1, 0)) == Result::kFull, "no input before the ring attaches");
  }
  {
    Logged t;
    t.stream.OpenInput();
    t.stream.AddInput(Input(UINT32_MAX, UINT32_MAX - 1, 1));
    t.stream.AddControl({Control(1, UINT32_MAX - 1, 0, 7)});
    t.stream.AddInput(Input(1, UINT32_MAX - 1, 2));
    t.stream.AddControl({Control(1, 1, 1, 8)});
    Check(t.log == std::vector<std::string>({"c7", "i1", "i2", "c8"}), "both seqs wrap");
  }
}

// --- The ordering case -----------------------------------------------------

enum Op : uint16_t { kActivate = 1, kIme = 2, kGeometry = 3, kNavigate = 4 };

// What cmux sent, in send order, and what the host must see.
struct Sent {
  std::deque<control::Message> controls;  // as the outbox let them out: coalesced geometry dropped
  std::deque<Header> inputs;
  std::vector<std::string> order;  // keys and IME commits: "k<id>" / "m<id>"
  std::vector<int32_t> key_page;   // by key id: the active page when it was sent
  size_t keys = 0, focus_changes = 0, ime_commits = 0, resizes = 0, clicks = 0, coalesced = 0, marks = 0;
};

// cmux's side: the remote shim's counters (remote_shim.mm Post and OrderInput)
// and a real control::Outbox, which the socket empties at random times. The
// geometry here is a keyed ordered op, as kOpDevtoolsSetPlacement is.
static Sent Send(std::mt19937& rng, size_t key_count) {
  Sent s;
  control::Outbox outbox(SIZE_MAX, SIZE_MAX);
  // The socket takes what waits: each frame decoded as the host reads it.
  auto drain = [&] {
    while (control::Outbox::Entry* entry = outbox.Front()) {
      std::deque<int> fds;
      control::Message m;
      size_t used = 0;
      const control::Parse parse = control::Decode(entry->bytes.data(), entry->bytes.size(), &fds, &m, &used);
      Check(parse == control::Parse::kFrame && used == entry->bytes.size(), "an outbox frame decodes whole");
      s.controls.push_back(std::move(m));
      outbox.PopFront();
    }
  };
  auto push = [&](const control::Message& m, std::optional<uint64_t> key, uint32_t boundary) {
    std::vector<uint8_t> bytes;
    Check(control::Encode(m, &bytes), "a control message encodes");
    if (outbox.Push(std::move(bytes), {}, key, 0, boundary)) ++s.coalesced;
  };
  uint32_t ctl = 0, input = 0;
  int32_t active = 1;
  int32_t width[3] = {0, 800, 800};
  std::uniform_int_distribution<int> pick(0, 99);
  auto ordered = [&](uint16_t op, int32_t a, int32_t b) {
    ctl = cmux_host::NextSeq(ctl);
    control::Message m;
    m.op = op;
    m.ctl_seq = ctl;
    m.after_input = input;
    m.fields = {control::Field::I32(0, a), control::Field::I32(1, b)};
    return m;
  };
  int32_t ime_id = 0;
  while (s.keys < key_count) {
    const int roll = pick(rng);
    if (pick(rng) < 10) drain();
    if (roll < 8) {
      active = 3 - active;  // focus moves to the other page
      push(ordered(kActivate, active, 0), std::nullopt, input);
      ++s.focus_changes;
    } else if (roll < 14) {
      const int32_t id = ++ime_id;
      control::Message m = ordered(kIme, active, id);
      if (pick(rng) < 5) {
        // Not sent (the host lacks it): its place goes as a seq mark.
        m.op = control::kOpSeqMark;
        m.fields.clear();
        ++s.marks;
      } else {
        s.order.push_back("m" + std::to_string(id));
        ++s.ime_commits;
      }
      push(m, std::nullopt, input);
    } else if (roll < 22) {
      const int32_t page = 1 + pick(rng) % 2;
      width[page] = 400 + pick(rng) * 10;
      // The outbox replaces a waiting geometry of the page with no input written since.
      push(ordered(kGeometry, page, width[page]), control::StateKey(kGeometry, page), input);
      ++s.resizes;
    } else if (roll < 25) {
      push(control::Message{kNavigate, false, 0, {control::Field::I32(0, active)}, {}, 0, 0}, std::nullopt, input);
    } else {
      input = cmux_host::NextSeq(input);
      Header h;
      h.seq = input;
      cmux_host::SetCtlSeq(&h, ctl);
      if (roll < 30) {
        h.kind = cmux_host::kMouse;  // a click: the host checks the width cmux saw
        h.v[2] = 1;
        h.v[0] = width[active];
        ++s.clicks;
      } else {
        h.kind = cmux_host::kKey;
        h.v[1] = static_cast<int32_t>(s.keys);
        s.key_page.push_back(active);
        s.order.push_back("k" + std::to_string(s.keys));
        ++s.keys;
      }
      s.inputs.push_back(h);
    }
  }
  drain();
  return s;
}

// The host's side: focus, IME and geometry from control, keys to the page the
// host has active.
struct Host {
  int32_t active = 1;
  int32_t width[3] = {0, 800, 800};
  std::vector<std::string> order;
  size_t misrouted_keys = 0, wrong_width_clicks = 0;
  const Sent* sent = nullptr;

  void Apply(const control::Message& m) {
    switch (m.op) {
      case kActivate:
        active = static_cast<int32_t>(m.fields[0].integer);
        break;
      case kIme:
        order.push_back("m" + std::to_string(m.fields[1].integer));
        break;
      case kGeometry:
        width[m.fields[0].integer] = static_cast<int32_t>(m.fields[1].integer);
        break;
      default:
        break;
    }
  }
  void Dispatch(const Header& h) {
    if (h.kind == cmux_host::kKey) {
      if (sent->key_page[h.v[1]] != active) ++misrouted_keys;
      order.push_back("k" + std::to_string(h.v[1]));
    } else if (h.v[0] != width[active]) {
      ++wrong_width_clicks;
    }
  }
};

// Delivers both streams in a random interleaving, each in its own order, in
// random batch sizes (the channel's per-drain batches, the ring's runs).
template <typename AddControl, typename AddInput>
static void Deliver(std::mt19937& rng, Sent sent, AddControl add_control, AddInput add_input) {
  std::uniform_int_distribution<int> side(0, 1);
  std::uniform_int_distribution<int> run(1, 40);
  while (!sent.controls.empty() || !sent.inputs.empty()) {
    const bool controls = sent.inputs.empty() || (!sent.controls.empty() && side(rng) == 0);
    int n = run(rng);
    if (controls) {
      std::vector<control::Message> batch;
      while (n-- > 0 && !sent.controls.empty()) {
        batch.push_back(std::move(sent.controls.front()));
        sent.controls.pop_front();
      }
      add_control(std::move(batch));
    } else {
      while (n-- > 0 && !sent.inputs.empty()) {
        if (!add_input(sent.inputs.front())) break;  // full: the ring keeps it
        sent.inputs.pop_front();
      }
    }
  }
}

static void TestOrderingCase() {
  std::mt19937 rng(92);
  for (int round = 0; round < 4; ++round) {
    const Sent sent = Send(rng, 10000);
    Host host;
    host.sent = &sent;
    bool malformed = false;
    control::OrderedStream stream([&host](std::vector<control::Message> run) {
      for (const control::Message& m : run) host.Apply(m);
    });
    stream.AttachInput([&host](const Header& h) { host.Dispatch(h); });
    stream.OpenInput();
    Deliver(
        rng, sent, [&](std::vector<control::Message> batch) { malformed |= stream.AddControl(std::move(batch)) == Result::kMalformed; },
        [&](const Header& h) {
          const Result r = stream.AddInput(h);
          malformed |= r == Result::kMalformed;
          return r != Result::kFull;
        });
    Check(!malformed, "the ordering case is never malformed");
    Check(stream.held_input() == 0 && stream.held_control() == 0, "everything was handed on");
    Check(host.misrouted_keys == 0, "each key lands on the page active when cmux sent it");
    Check(host.wrong_width_clicks == 0, "each click meets the geometry cmux had when it sent it");
    Check(host.order == sent.order, "keys and IME commits in send order");
    Check(sent.keys == 10000 && sent.focus_changes > 500 && sent.ime_commits > 300 && sent.resizes > 500 &&
              sent.coalesced > 0 && sent.marks > 0,
          "the case interleaves focus changes, IME commits, coalesced resizes and seq marks");

    // The same delivery with no barrier: what the host did before this task.
    Host naive;
    naive.sent = &sent;
    std::mt19937 again(static_cast<uint32_t>(round) + 1000);
    Deliver(
        again, sent,
        [&](std::vector<control::Message> batch) {
          for (const control::Message& m : batch) naive.Apply(m);
        },
        [&](const Header& h) {
          naive.Dispatch(h);
          return true;
        });
    Check(naive.misrouted_keys > 0, "without the barrier keys land on the wrong page (the test can fail)");
    std::fprintf(stderr, "chromium_host_order_test: round %d: %zu keys, %zu focus changes, %zu IME commits, %zu resizes (%zu coalesced), %zu marks; no barrier: %zu misrouted keys, %zu clicks off\n",
                 round, sent.keys, sent.focus_changes, sent.ime_commits, sent.resizes, sent.coalesced, sent.marks,
                 naive.misrouted_keys, naive.wrong_width_clicks);
  }
}

int main() {
  TestSeqHelpers();
  TestOrderedFrame();
  TestOutboxKeepsStateAcrossInput();
  TestFrameQueueKeepsInputAcrossControl();
  TestStreamChecks();
  TestStreamPassesNonInputKinds();
  TestOrderingCase();
  if (failures != 0) {
    std::fprintf(stderr, "chromium_host_order_test: %d failures\n", failures);
    return 1;
  }
  std::printf("chromium_host_order_test: ok\n");
  return 0;
}
