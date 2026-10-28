// Checks cmux_host::Encode/Decode (ChromiumHost/src/chromium_host_wire.h)
// against the golden frame that ChromiumHostFrameTests.swift checks too
// (scripts/cmux-next/tests/chromium-host-wire.test.sh).
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

#include "../src/chromium_host_wire.h"

static const char kGolden[] =
    "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
    "00001000000000000807060504030201010000000000000061004100efbeadde";

// Two wheel frames of one trackpad scroll, the same bytes
// as ChromiumHostFrameTests.wheelGolden: a gesture change (precise, shift held)
// and the momentum's start after the fingers lift.
static const char kWheelGolden[2][129] = {
    "0400000000000000780000002d0000006affffffd20400000400000000000000"
    "000002000000008055443322110000000700000000000000000000002a000000",
    "0400000000000000780000002d000000000000000af6ffff0000000001000000"
    "000000000000008056443322110000000700000000000000000000002b000000",
};

// An input presented frame, the same bytes as
// ChromiumHostFrameTests.inputPresentedGolden: the input of event time
// 0x1122334455 showed in a vsync frame at 0x1122a0b0c0.
static const char kInputPresentedGolden[] =
    "6e00000000000000010000000000000000000000000000000000000000000000"
    "00000000000000005544332211000000c0b0a022110000000000000000000000";

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

static void FromHex(const char* hex, uint8_t out[cmux_host::kHeaderSize]) {
  for (size_t i = 0; i < cmux_host::kHeaderSize; ++i) {
    unsigned value = 0;
    std::sscanf(hex + 2 * i, "%2x", &value);
    out[i] = static_cast<uint8_t>(value);
  }
}

static bool Near(double a, double b) {
  return std::fabs(a - b) < 1e-9;
}

// The wheel frame's phases, momentum phases and precise flag:
// before it the host got only whole-pixel deltas, so Chromium
// could not latch a gesture or hand the page a fling.
static void TestWheel() {
  using namespace cmux_host;
  Header changed;
  changed.kind = kWheel;
  changed.v[0] = 120;
  changed.v[1] = 45;
  changed.v[2] = -150;  // scrollingDeltaX -1.5
  changed.v[3] = 1234;  // scrollingDeltaY 12.34
  changed.v[4] = kNSPhaseChanged;
  changed.flags = kWheelPrecise | kNSFlagShift;
  changed.t0 = 0x1122334455ULL;
  changed.t1 = 7;
  changed.seq = 42;
  Header momentum;
  momentum.kind = kWheel;
  momentum.v[0] = 120;
  momentum.v[1] = 45;
  momentum.v[3] = -2550;
  momentum.v[5] = kNSPhaseBegan;
  momentum.flags = kWheelPrecise;
  momentum.t0 = 0x1122334456ULL;
  momentum.t1 = 7;
  momentum.seq = 43;
  const Header frames[2] = {changed, momentum};
  for (int i = 0; i < 2; ++i) {
    uint8_t golden[kHeaderSize], encoded[kHeaderSize];
    FromHex(kWheelGolden[i], golden);
    Encode(frames[i], encoded);
    Check(std::memcmp(encoded, golden, sizeof golden) == 0, "a wheel frame encodes as its golden bytes");
    Header d;
    Check(Decode(golden, &d) && d.v[4] == frames[i].v[4] && d.v[5] == frames[i].v[5] && d.flags == frames[i].flags,
          "a golden wheel frame decodes its phases and precise flag");
  }

  uint8_t golden[kHeaderSize];
  Header d;
  FromHex(kWheelGolden[0], golden);
  Decode(golden, &d);
  Wheel w = WheelOf(d);
  Check(w.x == 120 && w.y == 45 && Near(w.dx, -1.5) && Near(w.dy, 12.34), "position and fractional deltas");
  Check(w.precise && w.phase == kWheelPhaseChanged && w.momentum_phase == kWheelPhaseNone,
        "a gesture change is precise, changed, no momentum");
  Check(w.modifiers == kCefShiftDown, "shift becomes EVENTFLAG_SHIFT_DOWN");
  FromHex(kWheelGolden[1], golden);
  Decode(golden, &d);
  w = WheelOf(d);
  Check(w.phase == kWheelPhaseNone && w.momentum_phase == kWheelPhaseBegan && Near(w.dy, -25.5) && w.modifiers == 0,
        "the momentum's start has no gesture phase and a began momentum phase");

  // A whole trackpad scroll, encoded and decoded: every phase arrives as sent.
  const int32_t sent[][2] = {
      {kNSPhaseMayBegin, 0}, {kNSPhaseBegan, 0},    {kNSPhaseChanged, 0}, {kNSPhaseStationary, 0},
      {kNSPhaseEnded, 0},    {0, kNSPhaseBegan},    {0, kNSPhaseChanged}, {0, kNSPhaseEnded},
      {kNSPhaseCancelled, 0}, {0, 0},
  };
  const int expected[][2] = {
      {kWheelPhaseMayBegin, kWheelPhaseNone},  {kWheelPhaseBegan, kWheelPhaseNone},
      {kWheelPhaseChanged, kWheelPhaseNone},   {kWheelPhaseChanged, kWheelPhaseNone},
      {kWheelPhaseEnded, kWheelPhaseNone},     {kWheelPhaseNone, kWheelPhaseBegan},
      {kWheelPhaseNone, kWheelPhaseChanged},   {kWheelPhaseNone, kWheelPhaseEnded},
      {kWheelPhaseCancelled, kWheelPhaseNone}, {kWheelPhaseNone, kWheelPhaseNone},
  };
  static_assert(sizeof sent / sizeof sent[0] == sizeof expected / sizeof expected[0], "one expectation per frame");
  for (size_t i = 0; i < sizeof sent / sizeof sent[0]; ++i) {
    Header h;
    h.kind = kWheel;
    h.v[4] = sent[i][0];
    h.v[5] = sent[i][1];
    uint8_t bytes[kHeaderSize];
    Encode(h, bytes);
    Header back;
    Decode(bytes, &back);
    const Wheel got = WheelOf(back);
    Check(got.phase == expected[i][0] && got.momentum_phase == expected[i][1], "a scroll's phases round-trip");
  }

  // A notched mouse wheel (not precise, deltas in lines): the fork's wheel
  // call gets pixels, a line is 40, the same as the fallback.
  Header notch;
  notch.kind = kWheel;
  notch.v[2] = 50;    // half a line
  notch.v[3] = -100;  // one line
  w = WheelOf(notch);
  Check(!w.precise && Near(w.dx, 20) && Near(w.dy, -40), "the fork call gets a line of a mouse wheel as 40 pixels");
  WheelPixelCarry carry;
  WheelPixels px = carry.Take(1, notch);
  Check(px.dx == 20 && px.dy == -40, "the fallback gets a line of a mouse wheel as 40 pixels");

  // The fallback's whole pixels carry each frame's fraction to the next.
  Header slow;
  slow.kind = kWheel;
  slow.flags = kWheelPrecise;
  slow.v[3] = 30;  // 0.3 px
  slow.v[4] = kNSPhaseChanged;
  WheelPixelCarry slow_carry;
  int total = 0;
  for (int i = 0; i < 10; ++i) total += slow_carry.Take(1, slow).dy;
  Check(total == 3, "ten 0.3 px frames of a slow trackpad scroll scroll 3 px");
  Header fine = slow;
  fine.v[2] = -150;  // -1.5 px
  fine.v[3] = 1234;  // 12.34 px
  WheelPixelCarry fine_carry;
  px = fine_carry.Take(1, fine);
  Check(px.dx == -1 && px.dy == 12, "a frame sends its whole pixels");
  px = fine_carry.Take(1, fine);
  Check(px.dx == -2 && px.dy == 12, "and the next one its own plus the carried fraction");
  px = fine_carry.Take(2, slow);
  Check(px.dx == 0 && px.dy == 0, "another browser does not get the carry");
  Header begin = slow;
  begin.v[4] = kNSPhaseBegan;
  WheelPixelCarry edge_carry;
  for (int i = 0; i < 3; ++i) edge_carry.Take(1, slow);  // 0.9 px carried
  Check(edge_carry.Take(1, begin).dy == 0, "a new gesture starts with no carry");
  Header end = slow;
  end.v[4] = kNSPhaseEnded;
  edge_carry.Take(1, slow);
  edge_carry.Take(1, end);  // 0.9 px, then the gesture ends
  Header momentum_start = slow;
  momentum_start.v[4] = 0;
  momentum_start.v[5] = kNSPhaseChanged;
  Check(edge_carry.Take(1, momentum_start).dy == 0, "an ended gesture leaves no carry for the momentum");
  Check(CefModifiersOf(kNSFlagCapsLock | kNSFlagControl | kNSFlagOption | kNSFlagCommand | kWheelPrecise) ==
            (kCefCapsLockOn | kCefControlDown | kCefAltDown | kCefCommandDown),
        "modifier flags map to CEF's; the precise bit is not a modifier");

  // The host's queue folds a wheel only into one of the same phases.
  FrameQueue q(8);
  q.MarkReady();
  Header began = changed;
  began.v[4] = kNSPhaseBegan;
  q.Add(began, {});
  q.Add(changed, {});
  q.Add(changed, {});
  Header ended = changed;
  ended.v[4] = kNSPhaseEnded;
  ended.v[3] = 0;
  q.Add(ended, {});
  q.Add(momentum, {});
  q.Add(momentum, {});
  Header still = momentum;
  still.v[5] = kNSPhaseChanged;
  q.Add(still, {});
  auto taken = q.Take();
  Check(taken.size() == 5, "began, changed, ended, momentum began, momentum changed stay apart");
  Check(taken.size() == 5 && taken[1].header.v[3] == 2468 && taken[3].header.v[3] == -5100 &&
            taken[2].header.v[4] == kNSPhaseEnded && taken[4].header.v[5] == kNSPhaseChanged,
        "deltas add up only within one phase");
}

// An input frame's event time.
static void TestEventTime() {
  using namespace cmux_host;
  const uint64_t now = 5'000'000'000ULL;
  Header key;
  key.kind = kKey;
  key.t0 = now - 1'500'000;  // the NSEvent came 1.5 ms ago
  Check(EventTimeOf(key, now) == now - 1'500'000, "a key's event time is its t0, the NSEvent's timestamp");
  Header mouse = key;
  mouse.kind = kMouse;
  Header wheel = key;
  wheel.kind = kWheel;
  Check(EventTimeOf(mouse, now) == key.t0 && EventTimeOf(wheel, now) == key.t0,
        "so is a click's, a move's and a wheel's");
  Check(EventTimeOf(key, key.t0) == key.t0, "a t0 of now is now");
  Header future = key;
  future.t0 = now + 1;
  Check(EventTimeOf(future, now) == 0, "a t0 later than now is of another clock: Chromium stamps the send time");
  Header none = key;
  none.t0 = 0;
  Check(EventTimeOf(none, now) == 0, "a frame with no event time gets the send time");
  Header ping;
  ping.kind = kPing;
  ping.t0 = now - 10;
  Header geometry = key;
  geometry.kind = kGeometry;
  Check(EventTimeOf(ping, now) == 0 && EventTimeOf(geometry, now) == 0,
        "a ping's t0 (cmux's send time) and a geometry frame are not input events");
}

// The host's report that an input's frame was presented: before it cmux had
// no presentation time for a Chromium page's input.
static void TestInputPresented() {
  using namespace cmux_host;
  const Header frame = InputPresentedFrame(0x1122334455ULL, 0x1122a0b0c0ULL, kPresentationVSync);
  uint8_t golden[kHeaderSize], encoded[kHeaderSize];
  FromHex(kInputPresentedGolden, golden);
  Encode(frame, encoded);
  Check(std::memcmp(encoded, golden, sizeof golden) == 0, "an input presented frame encodes as its golden bytes");
  Header d;
  Check(Decode(golden, &d) && d.kind == kInputPresented && d.payload == 0, "it decodes as kInputPresented");
  Check(d.t0 == 0x1122334455ULL && d.t1 == 0x1122a0b0c0ULL, "t0 is the event time, t1 the presentation time");
  Check(static_cast<uint32_t>(d.v[0]) == kPresentationVSync, "v0 carries the feedback flags");
  // The capability rides kReady's v2, the bit ChromiumHostFrame.readyReportsInputPresented reads.
  Header ready;
  ready.kind = kReady;
  ready.v[2] = kReadyReportsInputPresented;
  uint8_t bytes[kHeaderSize];
  Encode(ready, bytes);
  Header readBack;
  Check(Decode(bytes, &readBack) && readBack.kind == kReady && readBack.v[2] == 1,
        "a ready that reports presentation carries bit 0 of v2");
}

int main() {
  uint8_t golden[cmux_host::kHeaderSize];
  FromHex(kGolden, golden);
  cmux_host::Header h;
  h.kind = cmux_host::kKey;
  h.payload = 3;
  h.v[0] = 10;
  h.v[1] = -2;
  h.v[2] = 0x7fffffff;
  h.v[3] = 3;
  h.v[4] = 4;
  h.v[5] = -1;
  h.flags = 0x100000;
  h.t0 = 0x0102030405060708ULL;
  h.t1 = 1;
  h.ch = 0x61;
  h.unmod = 0x41;
  h.seq = 0xdeadbeef;
  uint8_t encoded[cmux_host::kHeaderSize];
  cmux_host::Encode(h, encoded);
  Check(std::memcmp(encoded, golden, sizeof golden) == 0, "encode matches the golden frame");

  cmux_host::Header d;
  Check(cmux_host::Decode(golden, &d), "golden frame decodes");
  Check(d.kind == cmux_host::kKey && d.payload == 3, "kind and payload");
  Check(d.v[0] == 10 && d.v[1] == -2 && d.v[2] == 0x7fffffff && d.v[5] == -1, "signed values");
  Check(d.flags == 0x100000 && d.t0 == 0x0102030405060708ULL && d.t1 == 1, "flags and times");
  Check(d.ch == 0x61 && d.unmod == 0x41 && d.seq == 0xdeadbeef, "characters and seq");

  cmux_host::Header big;
  big.payload = cmux_host::kMaxPayload + 1;
  uint8_t too_long[cmux_host::kHeaderSize];
  cmux_host::Encode(big, too_long);
  Check(!cmux_host::Decode(too_long, &d), "a payload over the limit is refused");

  // The frame queue between the host's reader and its UI thread (FrameQueue).
  using Queue = cmux_host::FrameQueue;
  auto move_to = [](int x, int y) {
    cmux_host::Header m;
    m.kind = cmux_host::kMouse;
    m.v[0] = x;
    m.v[1] = y;
    m.t0 = static_cast<uint64_t>(x);
    return m;
  };
  cmux_host::Header key;
  key.kind = cmux_host::kKey;
  key.ch = 'a';
  {
    // Before the fix every frame was one posted task with no bound but a count: a UI thread that
    // stopped for a second while the pointer moved queued every move.
    Queue q(8);
    Check(q.Add(move_to(1, 1), {}) == Queue::Push::kWaiting, "nothing is posted before the UI thread exists");
    Check(q.MarkReady(), "the frames read so far are posted once the UI thread exists");
    for (int i = 2; i <= 1000; ++i) Check(q.Add(move_to(i, i), {}) != Queue::Push::kFull, "moves never fill the queue");
    Check(q.size() == 1, "a thousand moves while the UI thread waits are one move");
    auto taken = q.Take();
    Check(taken.size() == 1 && taken[0].header.v[0] == 1000 && taken[0].header.t0 == 1000, "the newest move is kept");
    Check(q.coalesced() == 999, "the folded moves are counted");
  }
  {
    Queue q(8);
    q.MarkReady();
    Check(q.Add(move_to(1, 1), {}) == Queue::Push::kWake, "the first frame after a drain posts one task");
    Check(q.Add(key, {}) == Queue::Push::kWaiting, "later frames ride the same task");
    q.Add(move_to(2, 2), {});
    q.Add(move_to(3, 3), {});
    cmux_host::Header up = key;
    up.v[0] = 1;
    q.Add(up, {});
    auto taken = q.Take();
    Check(taken.size() == 4, "a key between moves is never dropped and splits the moves");
    Check(taken.size() == 4 && taken[0].header.v[0] == 1 && taken[1].header.kind == cmux_host::kKey &&
              taken[2].header.v[0] == 3 && taken[3].header.v[0] == 1,
          "the order cmux sent is kept: move, key down, newest move, key up");
    Check(q.Add(move_to(4, 4), {}) == Queue::Push::kWake, "after a drain the next frame posts again");
  }
  {
    Queue q(8);
    q.MarkReady();
    cmux_host::Header wheel;
    wheel.kind = cmux_host::kWheel;
    wheel.v[2] = 1;
    wheel.v[3] = -10;
    q.Add(wheel, {});
    wheel.v[2] = 2;
    wheel.v[3] = -20;
    wheel.v[0] = 50;
    q.Add(wheel, {});
    cmux_host::Header down = move_to(5, 5);
    down.v[2] = 1;  // a click is not a move
    q.Add(down, {});
    q.Add(down, {});
    auto taken = q.Take();
    Check(taken.size() == 3, "wheel deltas add up; clicks are each kept");
    Check(taken.size() == 3 && taken[0].header.v[2] == 3 && taken[0].header.v[3] == -30 && taken[0].header.v[0] == 50,
          "the summed wheel frame has the newest position");
    cmux_host::Header shifted = move_to(6, 6);
    q.Add(move_to(5, 5), {});
    shifted.flags = 1u << 17;
    q.Add(shifted, {});
    Check(q.size() == 2, "a move with other modifier flags is its own frame");
  }
  {
    // Wheel ticks of another scroll phase, momentum phase or precision (kWheelPrecise in flags)
    // never fold.
    Queue q(8);
    q.MarkReady();
    cmux_host::Header began;
    began.kind = cmux_host::kWheel;
    began.v[3] = -1;
    began.v[4] = cmux_host::kNSPhaseBegan;
    began.flags = cmux_host::kWheelPrecise;
    q.Add(began, {});
    cmux_host::Header changed = began;
    changed.v[4] = cmux_host::kNSPhaseChanged;
    q.Add(changed, {});
    q.Add(changed, {});
    cmux_host::Header momentum = changed;
    momentum.v[4] = 0;
    momentum.v[5] = cmux_host::kNSPhaseChanged;
    q.Add(momentum, {});
    cmux_host::Header coarse = momentum;
    coarse.flags = 0;
    q.Add(coarse, {});
    auto taken = q.Take();
    Check(taken.size() == 4 && taken[1].header.v[3] == -2, "a wheel folds only into a tick of its own phase");
  }
  {
    Queue q(3);
    q.MarkReady();
    Check(q.Add(key, {}) != Queue::Push::kFull && q.Add(key, {}) != Queue::Push::kFull &&
              q.Add(key, {}) != Queue::Push::kFull,
          "three keys fit a limit of three");
    Check(q.Add(key, {}) == Queue::Push::kFull, "a fourth waiting key is a flood, refused and not queued");
    Check(q.Add(move_to(1, 1), {}) == Queue::Push::kFull, "so is a move with nothing to fold into");
    Check(q.size() == 3, "a refused frame is not queued");
    q.AddEnd();
    auto taken = q.Take();
    Check(taken.size() == 4 && taken.back().header.kind == cmux_host::kQuit, "the end is queued after every frame, even when full");
  }
  {
    Queue q(8);
    q.AddEnd();
    Check(q.MarkReady(), "an EOF before the UI thread exists runs once it does");
  }
  {
    // A pinch or pressure step (kGesture) is ordered input like a click,
    // and each step is kept: Chrome sends every pinch update (PinchEvent, render_widget_host_ns_view.mojom).
    cmux_host::Header pinch;
    pinch.kind = cmux_host::kGesture;
    pinch.v[2] = 1;
    pinch.v[3] = 1100000;
    Check(cmux_host::IsOrderedInput(pinch), "a gesture carries an input seq");
    Check(!cmux_host::IsPointerMove(pinch), "a gesture is not a pointer move");
    Queue q(8);
    q.MarkReady();
    q.Add(pinch, {});
    pinch.v[3] = 1200000;
    q.Add(pinch, {});
    auto taken = q.Take();
    Check(taken.size() == 2 && taken[0].header.v[3] == 1100000 && taken[1].header.v[3] == 1200000,
          "pinch steps are each kept, in order");
  }

  {
    // A click's button: left, middle and right are CEF's MBT_* values; a back
    // (3) or forward (4) button, or any other value, is no click, never a left click at the pointer.
    cmux_host::Header click;
    click.kind = cmux_host::kMouse;
    click.v[2] = 1;
    for (int32_t button = 0; button <= 2; ++button) {
      click.v[3] = button;
      Check(cmux_host::ClickButtonOf(click) == button, "left, middle and right click as themselves");
    }
    for (int32_t button : {3, 4, 5, -1, INT32_MAX}) {
      click.v[3] = button;
      Check(cmux_host::ClickButtonOf(click) == cmux_host::kNoClickButton, "a back or forward button is no click");
      Check(cmux_host::ClickButtonOf(click) != 0, "a back or forward button is never a left click");
    }
  }

  TestWheel();
  TestEventTime();
  TestInputPresented();

  if (failures) return 1;
  std::printf("chromium_host_wire_test: ok\n");
  return 0;
}
