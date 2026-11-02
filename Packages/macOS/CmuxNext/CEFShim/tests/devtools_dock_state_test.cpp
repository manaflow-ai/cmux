// The DevTools frontend's dock-side values (CEFShim/src/devtools_dock_state.h):
// each fork side maps to the frontend's own JSON-encoded setting value, the
// one the frontend reads when it loads (BROWSER VIDEO F2: a wrong or missing
// value lets the frontend move DevTools to its stored side after it opened).
// Run: scripts/cmux-next/test-shim-devtools-dock-cpp.sh

#include <cstdio>
#include <cstdlib>
#include <string>

#include "../src/devtools_dock_state.h"

using cmux_shim::DevToolsDockStateValue;

static int failures = 0;

static void expect_eq(const std::string& got, const std::string& want, const char* what) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got [%s], want [%s]\n", what, got.c_str(), want.c_str());
    ++failures;
  }
}

int main() {
  expect_eq(DevToolsDockStateValue(0), "\"undocked\"", "undocked");
  expect_eq(DevToolsDockStateValue(1), "\"left\"", "left");
  expect_eq(DevToolsDockStateValue(2), "\"bottom\"", "bottom");
  expect_eq(DevToolsDockStateValue(3), "\"right\"", "right");
  expect_eq(DevToolsDockStateValue(4), "", "an unknown side writes nothing");
  expect_eq(DevToolsDockStateValue(-1), "", "a negative side writes nothing");
  expect_eq(cmux_shim::kDevToolsDockStateKey, "currentDockState", "the frontend's setting name");
  if (failures) return EXIT_FAILURE;
  std::puts("devtools_dock_state_test: ok");
  return EXIT_SUCCESS;
}
