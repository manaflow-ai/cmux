// Checks cmux_shim::FindIds (CEFShim/src/find_ids.h): the find id a
// FIND_RESULT event carries is the caller's, from its browser's last
// cmux_shim_find (scripts/cmux-next/tests/shim-find-ids.test.sh).
#include <cstdio>

#include "../src/find_ids.h"

using cmux_shim::FindIds;

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

int main() {
  FindIds ids;
  Check(ids.Of(7) == 0, "a browser cmux never searched has id 0");

  // Each search replaces the id its results carry: Chromium drops the older
  // search's replies once the newer one started, so every later result is the
  // newer search's.
  ids.Sent(7, 1);
  Check(ids.Of(7) == 1, "results carry the search's find id");
  ids.Sent(7, 2);
  Check(ids.Of(7) == 2, "a newer search's results carry its id, not the older one's");

  // Browsers keep their own ids.
  ids.Sent(8, 5);
  Check(ids.Of(7) == 2 && ids.Of(8) == 5, "each browser keeps its last search's id");

  // A closed browser leaves nothing behind; a reused browser id starts over.
  ids.Forget(7);
  Check(ids.Of(7) == 0 && ids.Of(8) == 5, "Forget drops only that browser");
  Check(ids.size() == 1, "nothing is kept for a closed browser");
  ids.Forget(7);
  Check(ids.size() == 1, "forgetting twice is harmless");

  if (failures != 0) return 1;
  std::printf("find_ids: ok\n");
  return 0;
}
