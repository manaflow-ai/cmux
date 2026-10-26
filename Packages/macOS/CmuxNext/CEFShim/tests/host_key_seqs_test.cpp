// Checks cmux_shim::HostKeySeqs (CEFShim/src/host_key_seqs.h): the seq a key
// the page left unhandled goes back to cmux with in host mode
// (p01-process-030; scripts/cmux-next/tests/shim-host-key-seqs.test.sh).
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

int main() {
  constexpr uint32_t kShift = 1u << 1;
  constexpr uint32_t kControl = 1u << 2;
  constexpr uint32_t kCommand = 1u << 7;
  constexpr uint32_t kCapsLock = 1u << 0;
  constexpr uint32_t kIsLeft = 1u << 10;
  constexpr int kK = 40;  // kVK_ANSI_K
  constexpr int kF = 3;   // kVK_ANSI_F
  constexpr int kA = 0;   // kVK_ANSI_A

  {
    HostKeySeqs seqs;
    seqs.Note(1, 7, kK, kCommand);
    Check(seqs.Take(1, kK, kCommand) == 7, "an unhandled key returns its seq");
    Check(seqs.Take(1, kK, kCommand) == 0, "a seq is returned once");
    Check(seqs.Held(1) == 0, "nothing stays held");
  }
  {
    // Cmd-A and Cmd-F reached the page; it handled Cmd-A (no report) and left Cmd-F.
    HostKeySeqs seqs;
    seqs.Note(1, 1, kA, kCommand);
    seqs.Note(1, 2, kF, kCommand);
    seqs.Note(1, 3, kK, kCommand);
    Check(seqs.Take(1, kF, kCommand) == 2, "the report names the key it carries, not the oldest");
    Check(seqs.Held(1) == 1, "the handled older key is released with it");
    Check(seqs.Take(1, kA, kCommand) == 0, "a released key never comes back");
    Check(seqs.Take(1, kK, kCommand) == 3, "the newer key is still held");
  }
  {
    HostKeySeqs seqs;
    seqs.Note(1, 4, kK, kCommand);
    Check(seqs.Take(1, kK, kCommand | kShift) == 0, "Cmd-Shift-K is another key than Cmd-K");
    Check(seqs.Take(1, kK, kControl) == 0, "Ctrl-K is another key than Cmd-K");
    Check(seqs.Take(1, kK, kCommand | kCapsLock | kIsLeft) == 4, "caps lock and left/right flags name no key");
  }
  {
    HostKeySeqs seqs;
    seqs.Note(1, 5, kK, kCommand);
    Check(seqs.Take(2, kK, kCommand) == 0, "another page's report takes nothing");
    seqs.Forget(1);
    Check(seqs.Take(1, kK, kCommand) == 0, "a closed page holds nothing");
  }
  {
    HostKeySeqs seqs;
    seqs.Note(1, 0, kK, kCommand);
    Check(seqs.Held(1) == 0, "seq 0 is no key");
    Check(seqs.Take(1, kK, kCommand) == 0, "an in-process key has no seq");
  }
  {
    HostKeySeqs seqs;
    for (uint32_t seq = 1; seq <= HostKeySeqs::kLimit + 10; ++seq) seqs.Note(1, seq, kA, kCommand);
    Check(seqs.Held(1) == HostKeySeqs::kLimit, "a page that never reports holds at most the limit");
    Check(seqs.Take(1, kA, kCommand) == 11, "the oldest are dropped first");
  }
  if (failures) return 1;
  std::printf("host_key_seqs: ok\n");
  return 0;
}
