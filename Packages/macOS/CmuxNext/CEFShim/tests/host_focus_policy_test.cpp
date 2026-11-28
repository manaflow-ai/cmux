// Checks host_focus_policy.h: which of CEF's focus requests the Chromium host cancels, and the activation policy it
// holds while it starts (scripts/cmux-next/test-host-focus-policy-cpp.sh).
//
// A page open made its host the person's front app (in-tree pages approach 4, front-before-2, 2026-11-28): CEF's
// focus after a new browser's first navigation activated the host, and with cmux active macOS activated the host as
// it finished launching.
#include <iostream>

#include "../src/host_focus_policy.h"

int main() {
  int failed = 0;
  auto check = [&](const char* what, long got, long want) {
    if (got != want) {
      std::cerr << "FAIL " << what << ": got " << got << ", want " << want << "\n";
      ++failed;
    } else {
      std::cout << "ok   " << what << "\n";
    }
  };
  using namespace cmux_host;
  check("a navigation's focus is cancelled (it activated the host)", CancelsFocus(kFocusSourceNavigation), true);
  check("cmux's focus request keeps CEF's path", CancelsFocus(kFocusSourceSystem), false);
  check("prohibited while launching, before any page", ActivationPolicy(false, false), kActivationPolicyProhibited);
  check("prohibited when the page came before the launch finished", ActivationPolicy(false, true),
        kActivationPolicyProhibited);
  check("prohibited after the launch until the first page", ActivationPolicy(true, false),
        kActivationPolicyProhibited);
  check("accessory once launched with its first page", ActivationPolicy(true, true), kActivationPolicyAccessory);
  return failed ? 1 : 0;
}
