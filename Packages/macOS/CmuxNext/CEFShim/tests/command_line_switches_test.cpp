// Checks how the shim adds cmux's browser-process switches to a command line
// that already carries CEF's own feature lists
// (CEFShim/src/command_line_switches.h, no CEF needed;
// scripts/cmux-next/test-shim-switches-cpp.sh).
#include <cstdio>
#include <string>

#include "../src/command_line_switches.h"

using cmux_shim::IsFeatureListSwitch;
using cmux_shim::MergeFeatureList;
using cmux_shim::SafeStorageItemFor;

static int failures = 0;
static int cases = 0;

static void Check(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

int main() {
  Check(IsFeatureListSwitch("disable-features"), "disable-features is a feature list");
  Check(IsFeatureListSwitch("enable-features"), "enable-features is a feature list");
  Check(!IsFeatureListSwitch("load-extension"), "load-extension replaces its value");
  Check(!IsFeatureListSwitch("disable-features-x"), "only exact names are feature lists");

  // CEF puts its crash-avoidance list on the command line before
  // OnBeforeCommandLineProcessing; cmux's entry must keep every one of them.
  Check(MergeFeatureList("GlicActorUi,LensOverlay", "MacAppCodeSignClone") ==
            "GlicActorUi,LensOverlay,MacAppCodeSignClone",
        "cmux feature appends after CEF's list");
  Check(MergeFeatureList("", "MacAppCodeSignClone") == "MacAppCodeSignClone",
        "empty existing list");
  Check(MergeFeatureList("A,B", "") == "A,B", "empty added list keeps existing");
  Check(MergeFeatureList("A,B", "B,C") == "A,B,C", "duplicates appear once");
  Check(MergeFeatureList(" A , ,B,", "C, A") == "A,B,C", "blanks and spaces dropped");
  Check(MergeFeatureList("A<Trial", "A") == "A<Trial,A", "only exact entries deduplicate");

  // Each channel owns its keychain item; a shared one prompted on every
  // launch of every channel but the one that created it.
  auto nightly = SafeStorageItemFor("com.cmuxterm.app.nightly", {"disable-notifications"});
  Check(nightly.service == "cmux Safe Storage" && nightly.account == "com.cmuxterm.app.nightly",
        "nightly owns its item");
  auto next = SafeStorageItemFor("com.cmuxterm.app.nightly.cmux-next", {});
  Check(next.service == nightly.service && next.account != nightly.account,
        "two channels never share an item");
  Check(SafeStorageItemFor("com.cmuxterm.app.nightly", {"use-mock-keychain"}).service.empty(),
        "mock keychain reads no item");
  Check(SafeStorageItemFor("  ", {}).service.empty(), "no identifier keeps Chromium's item");
  Check(SafeStorageItemFor(" com.cmuxterm.app ", {}).account == "com.cmuxterm.app",
        "surrounding spaces dropped");

  std::printf("%d/%d command line switch cases passed\n", cases - failures, cases);
  return failures == 0 ? 0 : 1;
}
