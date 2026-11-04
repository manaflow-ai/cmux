// Which Chromium permission requests the host asks about (shim_permissions.mm),
// with no CEF (scripts/cmux-next/test-shim-permission-prompts-cpp.sh compiles
// it alone). Chrome draws every request in its permission bubble
// (chrome/browser/ui/views/permissions/permission_prompt_bubble_base_view.cc);
// cmux asks about location in its prompt bar. Screen sharing is not a permission prompt: it
// keeps Chromium's desktop media path (DisplayMediaAccessHandler and its
// DesktopMediaPicker), which task p01-process-228 shows in cmux.
#pragma once

#include <cstdint>

namespace cmux_shim {

// cef_permission_request_types_t (numeric, so the rule needs no CEF header).
inline constexpr uint32_t kPermissionGeolocation = 1u << 8;

// OnShowPermissionPrompt: the host asks about location alone. Anything else
// (camera and microphone included: Chromium's MediaStreamDevicesController
// asks through this call) keeps Chromium's default handling.
inline bool PromptGoesToHost(uint32_t requested) {
  return requested == kPermissionGeolocation;
}

// The token after `last` that `in_use` does not hold (1 ... INT32_MAX,
// wrapping; never 0). `last` is updated.
template <typename Map>
int NextPermissionToken(int& last, const Map& in_use) {
  do {
    last = last >= INT32_MAX || last < 0 ? 1 : last + 1;
  } while (in_use.count(last) != 0);
  return last;
}

}  // namespace cmux_shim
