// Who answers a page's permission request (CefPermissionHandler::OnShowPermissionPrompt).
// Chromium's own bubble anchors to a toolbar cmux never shows, so a request left with Chromium
// is never answered: the page's promise stays pending for as long as the page lives. No CEF
// dependency, so the test compiles it alone (scripts/cmux-next/test-permission-prompt-policy-cpp.sh);
// shim_permissions.mm checks these bit values against CEF's own.
#ifndef CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_
#define CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_

#include <cstdint>

namespace cmux_shim {

// cef_permission_request_types_t bits.
constexpr uint32_t kPermissionGeolocation = 1u << 8;
constexpr uint32_t kPermissionNotifications = 1u << 15;

// The kinds the host asks about in its prompt bar.
constexpr uint32_t kHostPermissions = kPermissionGeolocation;

enum class PermissionPromptRoute {
  // Chromium keeps the request (its default for the kind).
  kChromium,
  // The host asks the person in the page's prompt bar.
  kHost,
  // Refused at once: cmux shows nothing of this kind.
  kDeny,
};

// The route of a request for `requested` (a set of cef_permission_request_types_t bits).
// A request that groups a host kind with another stays with Chromium.
inline PermissionPromptRoute RoutePermissionPrompt(uint32_t requested) {
  if (requested == 0 || (requested & ~kHostPermissions) != 0) return PermissionPromptRoute::kChromium;
  return PermissionPromptRoute::kHost;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_
