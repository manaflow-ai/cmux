// The DevTools frontend's "loaded" signal (CEFShim/src/devtools_ready.h): the
// script the shim runs in the frontend relays its loadCompleted call (the
// message Chrome's DevToolsWindow waits for before it shows DevTools) as one
// console marker, and only that exact marker reveals the DevTools window
// (BROWSER VIDEO F1b: a dark-theme DevTools drew its unthemed white first paint
// for 1-5 frames before its theme applied).
// Run: scripts/cmux-next/test-shim-devtools-ready-cpp.sh

#include <cstdio>
#include <cstdlib>
#include <string>

#include "../src/devtools_ready.h"

using namespace cmux_shim;

static int failures = 0;

static void expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL %s\n", what);
    ++failures;
  }
}

int main() {
  const std::string script = DevToolsReadyScript();
  expect(script.find("loadCompleted") != std::string::npos, "the script waits for the frontend's loadCompleted");
  expect(script.find("sendMessageToEmbedder") != std::string::npos, "it relays the embedder message, not a timer");
  expect(script.find(kDevToolsReadyMarker) != std::string::npos, "it logs the marker");
  expect(script.find("requestAnimationFrame") != std::string::npos, "after the frontend's next frame");
  expect(IsDevToolsReadyMessage(kDevToolsReadyMarker), "the marker counts");
  expect(!IsDevToolsReadyMessage(std::string(kDevToolsReadyMarker) + " "), "only the exact marker counts");
  expect(!IsDevToolsReadyMessage("loadCompleted"), "another message does not");
  expect(!IsDevToolsReadyMessage(""), "an empty message does not");
  expect(kDevToolsRevealBackstopMs >= 1000 && kDevToolsRevealBackstopMs <= 3000,
         "a frontend that never reports still shows within 1-3 s of its load end");
  if (failures) return EXIT_FAILURE;
  std::puts("devtools_ready_test: ok");
  return EXIT_SUCCESS;
}
