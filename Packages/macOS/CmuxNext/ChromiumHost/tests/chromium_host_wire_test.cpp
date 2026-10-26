// Checks cmux_host::Encode/Decode (ChromiumHost/src/chromium_host_wire.h)
// against the golden frame that ChromiumHostFrameTests.swift checks too
// (scripts/cmux-next/tests/chromium-host-wire.test.sh).
#include <cstdio>
#include <cstring>
#include <string>

#include "../src/chromium_host_wire.h"

static const char kGolden[] =
    "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
    "00001000000000000807060504030201010000000000000061004100efbeadde";

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

int main() {
  uint8_t golden[cmux_host::kHeaderSize];
  for (size_t i = 0; i < cmux_host::kHeaderSize; ++i) {
    unsigned value = 0;
    std::sscanf(kGolden + 2 * i, "%2x", &value);
    golden[i] = static_cast<uint8_t>(value);
  }
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

  if (failures) return 1;
  std::printf("chromium_host_wire_test: ok\n");
  return 0;
}
