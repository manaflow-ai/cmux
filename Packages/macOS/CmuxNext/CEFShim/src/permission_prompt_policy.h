// Who answers a page's permission request (CefPermissionHandler::OnShowPermissionPrompt).
// Chromium's own bubble anchors to a toolbar cmux never shows, so a request left with Chromium
// is never answered: the page's promise stays pending for as long as the page lives. The kinds a
// page waits on (location, camera, microphone, notifications) go to the host's prompt bar instead.
// No CEF dependency, so the test compiles it alone (scripts/cmux-next/test-permission-prompt-policy-cpp.sh);
// shim_permissions.mm checks these bit values against CEF's own.
#ifndef CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_
#define CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_

#include <cstdint>

namespace cmux_shim {

// cef_permission_request_types_t bits.
constexpr uint32_t kPermissionCameraPanTiltZoom = 1u << 1;
constexpr uint32_t kPermissionCamera = 1u << 2;
constexpr uint32_t kPermissionGeolocation = 1u << 8;
constexpr uint32_t kPermissionMicrophone = 1u << 12;
constexpr uint32_t kPermissionNotifications = 1u << 15;

// The kinds the host asks about in its prompt bar. Camera and microphone ask there too: left with
// Chromium, a video call's getUserMedia() never resolved (meet.google.com waited on a camera it
// was never given). Chromium groups a page's camera and microphone request into one prompt, and
// pan-tilt-zoom rides with the camera (a page that asks for PTZ constraints).
constexpr uint32_t kHostPermissions =
    kPermissionGeolocation | kPermissionCamera | kPermissionMicrophone | kPermissionCameraPanTiltZoom;

// Notifications ask in the prompt bar too, alone: a Chromium tab's notifications reach the person
// through cmux's own banner (BrowserWebNotificationScript), shown only for a site the bar allowed.
// Before that bridge the request ended unanswered so that no refusal was stored against a later
// notification feature (Lawrence, 2026-11-11); Notification.requestPermission() then always read
// `default` (meet.google.com could never turn its notifications on).

// cef_media_access_permission_types_t bits (CefPermissionHandler::OnRequestMediaAccessPermission):
// getDisplayMedia() asks for the desktop kinds. Chromium's own screen picker is a dialog cmux
// never shows, so the page's promise stayed pending for good (cmux nightly 4510943012901).
constexpr uint32_t kMediaDesktopAudioCapture = 1u << 2;
constexpr uint32_t kMediaDesktopVideoCapture = 1u << 3;
constexpr uint32_t kMediaDesktopCapture = kMediaDesktopAudioCapture | kMediaDesktopVideoCapture;

// Not a CEF bit: the shim's PERMISSION_PROMPT event carries it for a screen-share question, so the
// host's prompt bar tells it from the kinds above (CEFPermissionPrompts.displayCapture).
constexpr uint32_t kPermissionDisplayCapture = 1u << 30;

// True for a media request that shares the screen (getDisplayMedia). The shim asks the host for
// these and ends each one, granted or cancelled; it never leaves one waiting on Chromium's picker.
inline bool IsDisplayCaptureRequest(uint32_t requested) {
  return (requested & kMediaDesktopCapture) != 0;
}

// What a granted display-capture request may use: the desktop kinds it asked for, nothing else
// (a request that also names the camera or microphone gets those from the permission prompt).
inline uint32_t DisplayCaptureGrant(uint32_t requested) {
  return requested & kMediaDesktopCapture;
}

enum class PermissionPromptRoute {
  // Chromium keeps the request (its default for the kind).
  kChromium,
  // The host asks the person in the page's prompt bar.
  kHost,
};

// The route of a request for `requested` (a set of cef_permission_request_types_t bits).
// A request that groups a host kind or notifications with another kind stays with Chromium.
inline PermissionPromptRoute RoutePermissionPrompt(uint32_t requested) {
  if (requested == kPermissionNotifications) return PermissionPromptRoute::kHost;
  if (requested == 0 || (requested & ~kHostPermissions) != 0) return PermissionPromptRoute::kChromium;
  return PermissionPromptRoute::kHost;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_PERMISSION_PROMPT_POLICY_H_
