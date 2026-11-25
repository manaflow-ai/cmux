// Checks cmux_shim::RoutePermissionPrompt: who answers a page's permission request
// (scripts/cmux-next/test-permission-prompt-policy-cpp.sh).
//
// A page that called Notification.requestPermission() in a Chromium tab waited for good
// (cmux nightly 1bd15914, 2026-11-10: still pending after 75 s, permission `default`): the
// request stayed with Chromium, whose bubble cmux never shows. It first ended unanswered
// (Lawrence, 2026-11-11: no refusal stored against a later notification feature); now that a
// Chromium tab's notifications reach cmux's banner, it asks in the host's prompt bar, so a site
// like meet.google.com can turn its notifications on. Camera and microphone
// requests waited for good the same way (a Meet call never got its camera), so they ask in
// the host's prompt bar like location.
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
  const uint32_t surface = 1u << 3;  // CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, a kind neither asked nor refused
  const uint32_t camera = cmux_shim::kPermissionCamera;
  const uint32_t mic = cmux_shim::kPermissionMicrophone;
  const Case cases[] = {
      {"location asks in the host's prompt bar", cmux_shim::kPermissionGeolocation, PermissionPromptRoute::kHost},
      {"a notification request asks in the host's prompt bar", cmux_shim::kPermissionNotifications,
       PermissionPromptRoute::kHost},
      {"notifications grouped with location stay with Chromium",
       cmux_shim::kPermissionNotifications | cmux_shim::kPermissionGeolocation, PermissionPromptRoute::kChromium},
      {"notifications grouped with another kind stay with Chromium", cmux_shim::kPermissionNotifications | surface,
       PermissionPromptRoute::kChromium},
      {"another kind keeps Chromium's default", surface, PermissionPromptRoute::kChromium},
      // A video call's getUserMedia() waited for good on Chromium's never-shown bubble.
      {"camera asks in the host's prompt bar", camera, PermissionPromptRoute::kHost},
      {"microphone asks in the host's prompt bar", mic, PermissionPromptRoute::kHost},
      {"camera and microphone together ask in the host's prompt bar", camera | mic, PermissionPromptRoute::kHost},
      {"camera with pan-tilt-zoom asks in the host's prompt bar", camera | cmux_shim::kPermissionCameraPanTiltZoom | mic,
       PermissionPromptRoute::kHost},
      {"camera grouped with another kind stays with Chromium", camera | surface, PermissionPromptRoute::kChromium},
      {"no kind keeps Chromium's default", 0, PermissionPromptRoute::kChromium},
  };
  int failures = 0;
  for (const Case& c : cases) {
    if (cmux_shim::RoutePermissionPrompt(c.requested) == c.want) continue;
    ++failures;
    std::cerr << "FAIL: " << c.what << " (bits " << c.requested << ", got "
              << static_cast<int>(cmux_shim::RoutePermissionPrompt(c.requested)) << ")\n";
  }
  // getDisplayMedia(): every desktop request goes to the host; a device-only request does not.
  struct MediaCase {
    const char* what;
    uint32_t requested;
    bool display;
    uint32_t grant;
  };
  const uint32_t video = cmux_shim::kMediaDesktopVideoCapture;
  const uint32_t audio = cmux_shim::kMediaDesktopAudioCapture;
  const uint32_t deviceVideo = 1u << 1;  // CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE
  const MediaCase media[] = {
      {"screen video is a display capture", video, true, video},
      {"screen video with audio grants both", video | audio, true, video | audio},
      {"a camera-only request is not a display capture", deviceVideo, false, 0},
      {"a display request never grants the camera", video | deviceVideo, true, video},
      {"no bits is not a display capture", 0, false, 0},
  };
  for (const MediaCase& c : media) {
    if (cmux_shim::IsDisplayCaptureRequest(c.requested) == c.display &&
        cmux_shim::DisplayCaptureGrant(c.requested) == c.grant)
      continue;
    ++failures;
    std::cerr << "FAIL: " << c.what << " (bits " << c.requested << ")\n";
  }
  if (failures != 0) return 1;
  std::cout << "permission prompt policy: " << (sizeof(cases) / sizeof(cases[0])) << " cases pass\n";
  return 0;
}
