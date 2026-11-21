// Checks cmux_shim::RoutePermissionPrompt: who answers a page's permission request
// (scripts/cmux-next/test-permission-prompt-policy-cpp.sh).
//
// A page that called Notification.requestPermission() in a Chromium tab waited for good
// (cmux nightly 1bd15914, 2026-11-10: still pending after 75 s, permission `default`): the
// request stayed with Chromium, whose bubble cmux never shows. cmux shows no web notification
// from a Chromium tab, so the request must end at once. It ends unanswered, never refused
// (Lawrence, 2026-11-11): a refusal is remembered for the site and would block a later real
// notification feature; unanswered, the permission stays `default`.
#include <cstdint>
#include <iostream>

#include "../src/permission_prompt_policy.h"

using cmux_shim::PermissionPromptRoute;

struct Case {
  const char* what;
  uint32_t requested;
  PermissionPromptRoute want;
};

int main() {
  const uint32_t camera = 1u << 3;  // CEF_PERMISSION_TYPE_CAMERA_STREAM, a kind neither asked nor refused
  const Case cases[] = {
      {"location asks in the host's prompt bar", cmux_shim::kPermissionGeolocation, PermissionPromptRoute::kHost},
      {"a notification request ends at once, unanswered", cmux_shim::kPermissionNotifications,
       PermissionPromptRoute::kEndUnanswered},
      {"notifications grouped with location stay with Chromium",
       cmux_shim::kPermissionNotifications | cmux_shim::kPermissionGeolocation, PermissionPromptRoute::kChromium},
      {"notifications grouped with another kind stay with Chromium", cmux_shim::kPermissionNotifications | camera,
       PermissionPromptRoute::kChromium},
      {"another kind keeps Chromium's default", camera, PermissionPromptRoute::kChromium},
      {"no kind keeps Chromium's default", 0, PermissionPromptRoute::kChromium},
  };
  int failures = 0;
  for (const Case& c : cases) {
    if (cmux_shim::RoutePermissionPrompt(c.requested) == c.want) continue;
    ++failures;
    std::cerr << "FAIL: " << c.what << " (bits " << c.requested << ", got "
              << static_cast<int>(cmux_shim::RoutePermissionPrompt(c.requested)) << ")\n";
  }
  if (failures != 0) return 1;
  std::cout << "permission prompt policy: " << (sizeof(cases) / sizeof(cases[0])) << " cases pass\n";
  return 0;
}
