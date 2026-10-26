// Which Chromium permission requests the host asks about (shim_permissions.mm),
// with no CEF (scripts/cmux-next/test-shim-permission-prompts-cpp.sh compiles
// it alone). Chrome draws every request in its permission bubble
// (chrome/browser/ui/views/permissions/permission_prompt_bubble_base_view.cc)
// and its screen picker (DesktopMediaPickerViews); cmux draws them from data.
#pragma once

#include <cstdint>
#include <string_view>

namespace cmux_shim {

// cef_permission_request_types_t (numeric, so the rule needs no CEF header).
inline constexpr uint32_t kPermissionGeolocation = 1u << 8;
// Every bit CEF 154 defines: AR_SESSION (1 << 0) to SENSORS (1 << 28).
inline constexpr uint32_t kKnownPermissions = (1u << 29) - 1;

// cef_media_access_permission_types_t.
inline constexpr uint32_t kMediaDeviceAudio = 1u << 0;
inline constexpr uint32_t kMediaDeviceVideo = 1u << 1;
inline constexpr uint32_t kMediaDesktopAudio = 1u << 2;
inline constexpr uint32_t kMediaDesktopVideo = 1u << 3;

// The default-off feature chromiumPermissionPromptsFromData (process chromium in
// schemas/features/features.d): every request kind goes to the host, not only
// location. The app lists it in --enable-features like a base::Feature;
// Chromium ignores a name it does not define.
inline constexpr std::string_view kPermissionPromptsFromDataFeature = "CmuxPermissionPromptsFromData";

// Whether the comma-separated feature `list` (an --enable-features or
// --disable-features value; an entry may carry a field trial suffix
// "<name>:<params>" or "<name><group>") names `feature`.
inline bool FeatureListHas(std::string_view list, std::string_view feature) {
  size_t start = 0;
  while (start <= list.size()) {
    size_t comma = list.find(',', start);
    if (comma == std::string_view::npos) comma = list.size();
    std::string_view entry = list.substr(start, comma - start);
    while (!entry.empty() && entry.front() == ' ') entry.remove_prefix(1);
    const size_t end = entry.find_first_of(":< ");
    if (entry.substr(0, end) == feature) return true;
    start = comma + 1;
  }
  return false;
}

// The feature is on when --enable-features names it and --disable-features
// does not (base::FeatureList: disable wins).
inline bool EveryKindFromFeatureLists(std::string_view enabled, std::string_view disabled) {
  return FeatureListHas(enabled, kPermissionPromptsFromDataFeature) &&
         !FeatureListHas(disabled, kPermissionPromptsFromDataFeature);
}

// PERMISSION_PROMPT's a: a permission prompt's cef_permission_request_types_t
// bits as they are, a media access request's (screen sharing)
// cef_media_access_permission_types_t bits above bit 32, so one value tells
// the host which CefPermissionHandler method asked.
inline int64_t MediaPromptBits(uint32_t media) {
  return static_cast<int64_t>(media) << 32;
}

// OnShowPermissionPrompt: the host asks when every bit is one cmux knows and,
// with the feature off, only location is asked for. Anything else keeps
// Chromium's default handling.
inline bool PromptGoesToHost(bool every_kind, uint32_t requested) {
  if (requested == 0 || (requested & ~kKnownPermissions) != 0) return false;
  return every_kind || (requested & ~kPermissionGeolocation) == 0;
}

// OnRequestMediaAccessPermission: a screen share (getDisplayMedia, or a
// desktop getUserMedia) goes to the host with the feature on. Camera and
// microphone keep Chromium's MediaStreamDevicesController, which picks the
// devices and asks through OnShowPermissionPrompt (CAMERA_STREAM,
// MIC_STREAM). A request that mixes a device with the screen stays with
// Chromium, so no camera or microphone is granted by a screen question.
inline bool MediaGoesToHost(bool every_kind, uint32_t requested) {
  const uint32_t desktop = kMediaDesktopAudio | kMediaDesktopVideo;
  return every_kind && (requested & kMediaDesktopVideo) != 0 && (requested & ~desktop) == 0;
}

// The bits CefMediaAccessCallback::Continue gets for the host's answer:
// 1 allows what was asked; anything else allows nothing (the page's request
// fails with NotAllowedError).
inline uint32_t MediaAllowed(int result, uint32_t requested) {
  return result == 1 ? requested : 0;
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
