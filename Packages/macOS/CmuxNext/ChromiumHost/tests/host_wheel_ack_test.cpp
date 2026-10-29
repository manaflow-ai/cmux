// Checks the Chromium Host's wheel acks (src/host_wheel_ack.h)
// alone and through the dispatcher (src/host_dispatch.mm)
// with a fake shim and a fake fork handler: the fork's struct is read with
// its size; an ack goes out as one CMUX_SHIM_WHEEL_ACK under cmux's id with
// the input seq of the wheel it answers (the page's oldest unacked one, with
// several in flight), its scrolled DIPs, flags,
// overscroll-behavior-x and overscroll; a momentum wheel's ack, an ack of a
// page given no wheel and acks after the page closed go nowhere; the HELLO
// lists kWheelAcksHelloName only on a fork with the handler, which Resume
// installs. Whether a swipe starts from these is chromium-host-bench.py's
// swipe row (fleet).
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_wheel_ack.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;
using cmux_host::control::Message;
using Writer = cmux_host::control::TlvWriter;

constexpr int32_t kMinted = 1 << 20;
constexpr int kChromiumBrowser = 3;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The fake shim and fork: the handler the dispatcher installed.
struct Fork {
  HostContext* host = nullptr;
  WheelAckFn fn = nullptr;
  void* ctx = nullptr;
  int sets = 0;
  int live = 0;
} fake;

int SetHandler(WheelAckFn fn, void* ctx) {
  ++fake.sets;
  fake.fn = fn;
  fake.ctx = ctx;
  return 1;
}

ForkWheelAck Ack(int flags, float consumed_x, float consumed_y, float overscroll_x = 0, int behavior = 0) {
  ForkWheelAck ack{};
  ack.size = static_cast<int>(sizeof(ForkWheelAck));
  ack.flags = flags;
  ack.consumed_x = consumed_x;
  ack.consumed_y = consumed_y;
  ack.overscroll_x = overscroll_x;
  ack.overscroll_behavior_x = behavior;
  return ack;
}

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++fake.live;
  HostContext::OnShimEvent(fake.host, CMUX_SHIM_AFTER_CREATED, kChromiumBrowser, request, 0, 0, "", "");
  return 1;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return fake.live; }
}

namespace {

struct Delegate : HostDelegate {
  std::vector<std::string> calls;
  void Initialize(InitializeRequest) override { calls.push_back("initialize"); }
  void Quit() override { calls.push_back("quit"); }
  void BrowserClosed() override { calls.push_back("closed"); }
  void BadMessage(const std::string& what) override { calls.push_back("bad " + what); }
};

struct Views : PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const PageGeometry&) override {}
};

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

struct Event {
  int32_t kind, browser, request;
  int64_t a, b;
};

struct Fixture {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr};
  std::vector<std::string> hello_exports;

  explicit Fixture(SetWheelAckHandlerFn set) {
    fake = Fork();
    fake.host = &host;
    host.SetWheelAckHandler(set);
    host.Attach();
    for (const Message& m : sent) {
      if (m.op != control::kOpHello) continue;
      control::TlvReader r(m.fields);
      r.Str();
      hello_exports = r.StrList();
    }
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host.OnMessages({Op(control::kOpHello, 0, hello)});
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host.OnMessages({Op(kOpInitialize, 1, init)});
    host.Resume();
    Writer create;
    create.I32(kMinted);
    create.I32(42);
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host.OnMessages({Op(kOpCreateWindow, 2, create)});
    sent.clear();
  }

  bool Listed() const {
    for (const std::string& name : hello_exports) {
      if (name == kWheelAcksHelloName) return true;
    }
    return false;
  }

  void Acked(int browser, const ForkWheelAck& ack) {
    if (fake.fn) fake.fn(fake.ctx, browser, &ack);
  }

  // The WHEEL_ACK events sent since the last call.
  std::vector<Event> Acks() {
    std::vector<Event> out;
    for (const Message& m : sent) {
      if (m.op != kOpEvent) continue;
      control::TlvReader r(m.fields);
      Event e{r.I32(), r.I32(), r.I32(), r.I64(), r.I64()};
      r.Str();
      r.Str();
      Check(r.ok() && r.AtEnd(), "an event decodes");
      if (e.kind == kEventWheelAck) out.push_back(e);
    }
    sent.clear();
    return out;
  }
};

void ReadsTheForkStruct() {
  WheelAck read;
  ForkWheelAck ack = Ack(kWheelAckUpdate | kWheelAckOverscrolled | (1 << 9), 1.5f, -2.25f, -12.5f, kOverscrollContain);
  Check(ReadForkWheelAck(&ack, &read), "the first layout reads");
  Check(read.flags == (kWheelAckUpdate | kWheelAckOverscrolled), "unknown flag bits are dropped");
  Check(read.consumed_x == 1.5f && read.consumed_y == -2.25f && read.overscroll_x == -12.5f, "consumed and overscroll DIPs");
  Check(read.overscroll_behavior_x == kOverscrollContain, "overscroll-behavior-x");

  ack.overscroll_behavior_x = 7;
  Check(ReadForkWheelAck(&ack, &read) && read.overscroll_behavior_x == kOverscrollNone,
        "an unknown behavior reads as none: the page keeps the overscroll");

  WheelAck untouched;
  untouched.flags = kWheelAckConsumed;
  ForkWheelAck old = ack;
  old.size = static_cast<int>(sizeof(ForkWheelAck)) - 4;
  Check(!ReadForkWheelAck(&old, &untouched) && untouched.flags == kWheelAckConsumed, "an older struct is refused");
  Check(!ReadForkWheelAck(nullptr, &untouched), "no ack is refused");
}

void EncodesTheEvent() {
  WheelAck ack;
  ack.flags = kWheelAckUpdate | kWheelAckConsumed;
  ack.consumed_x = 0;
  ack.consumed_y = -3.5f;
  ack.overscroll_x = 40;  // no kWheelAckOverscrolled: not sent
  ack.overscroll_behavior_x = kOverscrollNone;
  WheelAckEvent event = EncodeWheelAck(0xFFFFFFF0u, ack);
  Check(event.request == static_cast<int32_t>(0xFFFFFFF0u), "request is the seq's bits");
  Check(static_cast<int32_t>(event.a & 0xFFFFFFFF) == 0 && static_cast<int32_t>(event.a >> 32) == -350,
        "a: consumed x low, y high, in hundredths");
  Check(event.b == (kWheelAckUpdate | kWheelAckConsumed), "no overscroll: flags only");

  ack.flags = kWheelAckUpdate | kWheelAckOverscrolled;
  ack.consumed_y = 0;
  ack.overscroll_x = -12.34f;
  ack.overscroll_behavior_x = kOverscrollContain;
  event = EncodeWheelAck(5, ack);
  Check((event.b & 0xFF) == (kWheelAckUpdate | kWheelAckOverscrolled), "b: flags in the low bits");
  Check(((event.b >> kWheelAckBehaviorShift) & 3) == kOverscrollContain, "b: behavior in bits 8-9");
  Check(static_cast<int32_t>(event.b >> 32) == -1234, "b: overscroll x in hundredths in the high 32 bits");

  Check(Hundredths(1e30f) == INT32_MAX && Hundredths(-1e30f) == INT32_MIN && Hundredths(std::nanf("")) == 0,
        "hundredths clamp and NaN is 0");
}

void PairsEachAckWithItsWheel() {
  WheelAcks acks;
  WheelAck ack;
  ack.flags = kWheelAckUpdate;
  Check(!acks.Acked(3, &ack), "a page given no wheel: no event");

  // Several wheels in flight (042 acks at dispatch): each ack answers the oldest.
  acks.Sent(3, 10, false);
  acks.Sent(3, 11, false);
  Check(acks.InFlight(3) == 2, "both wheels are in flight");
  std::optional<WheelAckEvent> first = acks.Acked(3, &ack);
  std::optional<WheelAckEvent> second = acks.Acked(3, &ack);
  Check(first && first->request == 10 && second && second->request == 11, "acks in the order the wheels went");
  Check(!acks.Acked(3, &ack) && acks.size() == 0, "every wheel acked: a further ack names none");

  // A fling's last momentum wheel, then a new gesture's began wheel, before either is acked: the
  // momentum wheel's (consumed) ack goes nowhere, and the began wheel's (unconsumed) ack names it.
  acks.Sent(3, 1, true);
  acks.Sent(3, 2, false);
  WheelAck consumed;
  consumed.flags = kWheelAckUpdate | kWheelAckConsumed;
  WheelAck unconsumed;
  unconsumed.flags = kWheelAckUpdate | kWheelAckOverscrolled;
  Check(!acks.Acked(3, &consumed), "the momentum wheel's ack: no event, and not the began wheel's");
  second = acks.Acked(3, &unconsumed);
  Check(second && second->request == 2 && (second->b & kWheelAckConsumed) == 0,
        "the began wheel's ack carries its own seq and flags");

  acks.Sent(3, 0, false);
  acks.Sent(3, 13, false);
  Check(!acks.Acked(3, &ack), "a wheel cmux stamped no seq on: no event");
  first = acks.Acked(3, &ack);
  Check(first && first->request == 13, "the next wheel's ack is still its own");

  acks.Sent(4, 20, false);
  acks.Sent(5, 30, false);
  first = acks.Acked(5, &ack);
  Check(first && first->request == 30 && acks.InFlight(4) == 1, "pages' queues are apart");
  acks.Forget(4);
  Check(!acks.Acked(4, &ack) && acks.size() == 0, "a closed page is forgotten");

  for (uint32_t seq = 1; seq <= WheelAcks::kMaxInFlight + 2; ++seq) acks.Sent(6, seq, false);
  Check(acks.InFlight(6) == WheelAcks::kMaxInFlight, "a page's queue is bounded");
  first = acks.Acked(6, &ack);
  Check(first && first->request == 3, "past the bound the oldest went");
}

void ForwardsAcksThroughTheDispatcher() {
  Fixture f(&SetHandler);
  Check(f.Listed(), "the HELLO lists kWheelAcksHelloName on a fork with the handler");
  Check(fake.sets == 1 && fake.fn == &HostContext::OnWheelAck && fake.ctx == &f.host, "Resume installs the handler once");

  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate, 0, 0));
  Check(f.Acks().empty(), "an ack before any wheel goes nowhere");

  f.host.WheelSent(kChromiumBrowser, 77, false);
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate | kWheelAckOverscrolled, 0, 0, -30, kOverscrollAuto));
  std::vector<Event> acks = f.Acks();
  Check(acks.size() == 1, "one ack, one event");
  if (acks.size() == 1) {
    Check(acks[0].browser == kMinted, "under the id cmux minted");
    Check(acks[0].request == 77, "with the wheel's input seq");
    Check((acks[0].b & 0xFF) == (kWheelAckUpdate | kWheelAckOverscrolled) && static_cast<int32_t>(acks[0].b >> 32) == -3000,
          "its flags and overscroll");
  }

  f.host.WheelSent(kChromiumBrowser, 78, false);
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate | kWheelAckConsumed, 4.5f, 0));
  acks = f.Acks();
  Check(acks.size() == 1 && acks[0].request == 78 && static_cast<int32_t>(acks[0].a & 0xFFFFFFFF) == 450,
        "a consumed update with the DIPs it scrolled");

  f.host.WheelSent(kChromiumBrowser, 79, true);
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate, 0, 0));
  Check(f.Acks().empty(), "a momentum wheel's ack goes nowhere");

  ForkWheelAck old = Ack(kWheelAckUpdate, 0, 0);
  old.size = 8;
  f.host.WheelSent(kChromiumBrowser, 80, false);
  f.host.WheelSent(kChromiumBrowser, 81, false);
  f.Acked(kChromiumBrowser, old);
  Check(f.Acks().empty(), "an ack the host cannot read goes nowhere");
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate, 0, 0));
  acks = f.Acks();
  Check(acks.size() == 1 && acks[0].request == 81, "but it answered its wheel: the next ack names the next one");

  // A vertical fling's momentum wheel still in flight when the next gesture begins: its consumed ack
  // is not the began wheel's, so the began wheel's unconsumed ack goes out under its own seq.
  f.host.WheelSent(kChromiumBrowser, 90, true);
  f.host.WheelSent(kChromiumBrowser, 91, false);
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate | kWheelAckConsumed, 0, 12));
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate | kWheelAckOverscrolled, 0, 0, -8, kOverscrollAuto));
  acks = f.Acks();
  Check(acks.size() == 1 && acks[0].request == 91 && (acks[0].b & kWheelAckConsumed) == 0 &&
            (acks[0].b & kWheelAckOverscrolled) != 0,
        "one event: the began wheel's unconsumed overscroll");

  HostContext::OnShimEvent(&f.host, CMUX_SHIM_BEFORE_CLOSE, kChromiumBrowser, 0, 0, 0, "", "");
  f.sent.clear();
  f.Acked(kChromiumBrowser, Ack(kWheelAckUpdate, 0, 0));
  Check(f.Acks().empty() && f.host.wheel_acks().size() == 0, "a closed page's acks go nowhere");
  Check(f.delegate.calls == std::vector<std::string>({"initialize", "closed"}), "no bad message");
}

void NoHandlerNoAcks() {
  Fixture f(nullptr);
  Check(!f.Listed(), "a fork without the handler: the HELLO does not list it");
  Check(fake.sets == 0 && fake.fn == nullptr, "nothing installed");
}

}  // namespace

int main() {
  ReadsTheForkStruct();
  EncodesTheEvent();
  PairsEachAckWithItsWheel();
  ForwardsAcksThroughTheDispatcher();
  NoHandlerNoAcks();
  if (failures) {
    std::fprintf(stderr, "chromium-host-wheel-ack: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("chromium-host-wheel-ack tests: ok\n");
  return 0;
}
