// Checks cmux_shim::HostKeySeqs (CEFShim/src/host_key_seqs.h): the input seq a
// chord the page left unhandled goes back to cmux with in host mode
// (scripts/cmux-next/tests/shim-host-key-seqs.test.sh).
#include <cstdio>

#include "../src/host_key_seqs.h"

using cmux_shim::HostKeySeqs;

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// What SendHostKeyEvent does around CefBrowserHost::SendKeyEvent, which calls
// OnPreKeyEvent (Bind) with the event it queues for the page.
static void Send(HostKeySeqs& seqs, int browser, uint32_t seq, const void* queued) {
  seqs.Expect(browser, seq);
  seqs.Bind(browser, queued);
  seqs.EndSend();
}

// What OnKeyEvent emits for an unhandled key-down in the Chromium Host:
// KEY_UNHANDLED's request and b, or request -1 when it reports nothing.
struct Report {
  int request = -1;
  int64_t b = 0;
};
static Report Unhandled(HostKeySeqs& seqs, int browser, const void* queued, uint32_t modifiers) {
  const uint32_t seq = seqs.Take(browser, queued);
  if (!HostKeySeqs::ReportsChord(false, seq, modifiers)) return Report{};
  return Report{static_cast<int>(seq), HostKeySeqs::ChordBits(modifiers)};
}

int main() {
  constexpr uint32_t kShift = HostKeySeqs::kShiftDown;
  constexpr uint32_t kControl = HostKeySeqs::kControlDown;
  constexpr uint32_t kCommand = HostKeySeqs::kCommandDown;
  constexpr uint32_t kAlt = 1u << 3;
  int e1, e2, e3;  // stand-ins for the NSEvents CEF queues
  const void* a = &e1;
  const void* b = &e2;
  const void* c = &e3;

  {
    // One round trip: the kKey frame with input seq 7, then the page leaves it unhandled.
    HostKeySeqs seqs;
    Send(seqs, 1, 7, a);
    const Report report = Unhandled(seqs, 1, a, kCommand);
    Check(report.request == 7, "KEY_UNHANDLED carries the frame's input seq");
    Check(report.b == HostKeySeqs::kChordBit, "b bit 1 marks a chord");
    Check(Unhandled(seqs, 1, a, kCommand).request == -1, "a seq is reported once");
    Check(seqs.Held(1) == 0, "nothing stays held");
  }
  {
    Check(HostKeySeqs::ChordBits(kCommand | kShift) == (HostKeySeqs::kChordBit | HostKeySeqs::kShiftBit),
          "b bit 0 carries Shift");
    Check(!HostKeySeqs::ReportsChord(true, 7, kCommand), "in process the unhandled-key handler answers");
    Check(!HostKeySeqs::ReportsChord(false, 0, kCommand), "a key that came with no seq is not reported");
    Check(!HostKeySeqs::ReportsChord(false, 7, kAlt), "an Option key is no chord");
    Check(HostKeySeqs::ReportsChord(false, 7, kControl), "a Control key is");
  }
  {
    // The same chord twice: the page handled the first Cmd-K (no report) and left the second.
    HostKeySeqs seqs;
    Send(seqs, 1, 3, a);
    Send(seqs, 1, 9, b);
    Check(Unhandled(seqs, 1, b, kCommand).request == 9, "the report names its own key, not an older one");
    Check(seqs.Held(1) == 1, "the handled key is not taken for it");
    Send(seqs, 1, 12, c);
    Check(Unhandled(seqs, 1, c, kCommand).request == 12, "the next report pairs with the next key");
  }
  {
    // A handled key's event was freed, and Chromium queued a new one at its address.
    HostKeySeqs seqs;
    Send(seqs, 1, 3, a);
    Send(seqs, 1, 9, a);
    Check(seqs.Held(1) == 1, "a reused address replaces the acked key");
    Check(seqs.Take(1, a) == 9, "and names the new key");
  }
  {
    HostKeySeqs seqs;
    Send(seqs, 1, 5, a);
    Send(seqs, 2, 6, b);
    Check(seqs.Take(2, a) == 0, "another page's event takes nothing");
    Check(seqs.Take(2, b) == 6, "each page reports its own keys");
    Check(seqs.Take(1, a) == 5, "the other page's key is still held");
    Send(seqs, 1, 8, c);
    seqs.Forget(1);
    Check(seqs.Take(1, c) == 0, "a closed page holds nothing");
  }
  {
    HostKeySeqs seqs;
    seqs.Expect(1, 4);
    seqs.EndSend();  // Chromium queued nothing (no page widget)
    seqs.Bind(1, a);
    Check(seqs.Held(1) == 0, "a key the host did not send binds to no seq");
    seqs.Bind(1, b);
    Check(seqs.Take(1, b) == 0, "an in-process key has no seq");
    seqs.Expect(2, 4);
    seqs.Bind(1, a);
    Check(seqs.Held(1) == 0, "a key expected for another page does not bind here");
    seqs.EndSend();
    seqs.Expect(1, 0);
    seqs.Bind(1, a);
    Check(seqs.Held(1) == 0, "seq 0 is no key");
  }
  {
    HostKeySeqs seqs;
    static int events[HostKeySeqs::kLimit + 10];
    for (uint32_t i = 0; i < HostKeySeqs::kLimit + 10; ++i) Send(seqs, 1, i + 1, &events[i]);
    Check(seqs.Held(1) == HostKeySeqs::kLimit, "a page that handles every key holds at most the limit");
    Check(seqs.Take(1, &events[9]) == 0, "the oldest are dropped first");
    Check(seqs.Take(1, &events[10]) == 11, "the newer ones stay");
  }
  if (failures) return 1;
  std::printf("host_key_seqs: ok\n");
  return 0;
}
