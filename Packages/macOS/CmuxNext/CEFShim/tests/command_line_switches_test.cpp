// Checks how the shim adds cmux's browser-process switches to a command line
// that already carries CEF's own feature lists
// (CEFShim/src/command_line_switches.h, no CEF needed;
// scripts/cmux-next/test-shim-switches-cpp.sh).
#include <cstdio>
#include <string>
#include <vector>

#include "../src/command_line_switches.h"

using cmux_shim::IsFeatureListSwitch;
using cmux_shim::MergeFeatureList;
using cmux_shim::PlanSwitches;
using cmux_shim::Switch;

static bool Has(const std::vector<Switch>& plan, const std::string& name) {
  for (const Switch& s : plan) {
    if (s.name == name) return true;
  }
  return false;
}

static std::string ValueOf(const std::vector<Switch>& plan, const std::string& name) {
  for (const Switch& s : plan) {
    if (s.name == name) return s.value;
  }
  return "<missing>";
}

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

  // Sandbox guard (CVE-2026-106378, pwn.ai chrome-escape): no switch that
  // weakens the sandbox or site isolation reaches Chromium, from cmux's list
  // or from the process's own argv.
  {
    std::vector<std::string> dropped;
    auto plan = PlanSwitches({{"no-sandbox", ""}, {"type", ""}},
                             {"disable-gpu-sandbox", "single-process", "in-process-gpu",
                              "disable-web-security", "no-first-run", "gpu-launcher=/bin/sh"},
                             &dropped);
    Check(!Has(plan, "no-sandbox"), "argv no-sandbox is removed");
    Check(!Has(plan, "disable-gpu-sandbox"), "disable-gpu-sandbox is refused");
    Check(!Has(plan, "single-process"), "single-process is refused");
    Check(!Has(plan, "in-process-gpu"), "in-process-gpu is refused");
    Check(!Has(plan, "disable-web-security"), "disable-web-security is refused");
    Check(!Has(plan, "gpu-launcher"), "gpu-launcher is refused");
    Check(Has(plan, "no-first-run"), "ordinary switches are kept");
    Check(Has(plan, "type"), "existing ordinary switches are kept");
    Check(dropped.size() == 6, "every refused switch is reported");
  }
  {
    auto plan = PlanSwitches({{"disable-features", "GlicActorUi,MacDisclaimGpuTccResponsibility"}},
                             {"disable-features=SystemNotifications,SitePerProcess<Trial",
                              "disable-features=IsolateOrigins:x/y"});
    Check(ValueOf(plan, "disable-features") == "GlicActorUi,SystemNotifications",
          "guarded features cannot be disabled; the rest of the list stays");
  }
  {
    auto plan = PlanSwitches({}, {"disable-features=MacDisclaimGpuTccResponsibility"});
    Check(!Has(plan, "disable-features"), "a list of only guarded features goes away");
  }
  {
    auto plan = PlanSwitches({{"disable-features", "A"}}, {"disable-features=B", "load-extension=/x"});
    Check(ValueOf(plan, "disable-features") == "A,B", "feature lists still merge");
    Check(ValueOf(plan, "load-extension") == "/x", "values are kept");
  }
  Check(cmux_shim::IsSandboxWeakeningSwitch("--no-sandbox"), "leading dashes are ignored");
  Check(!cmux_shim::IsSandboxWeakeningSwitch("no-sandbox-x"), "only exact names are refused");

  std::printf("%d/%d command line switch cases passed\n", cases - failures, cases);
  return failures == 0 ? 0 : 1;
}
