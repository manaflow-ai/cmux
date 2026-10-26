// Cases of which Chromium permission requests the host asks about
// (CEFShim/src/permission_prompt_policy.h):
// scripts/cmux-next/test-shim-permission-prompts-cpp.sh.
#include "../src/permission_prompt_policy.h"

#include <cstdio>
#include <map>

namespace {
int failures = 0;
void Expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}
}  // namespace

int main() {
  using namespace cmux_shim;
  constexpr uint32_t camera = 1u << 2, microphone = 1u << 12, notifications = 1u << 15, sensors = 1u << 28;

  Expect(PromptGoesToHost(false, kPermissionGeolocation), "feature off: location goes to the host");
  Expect(!PromptGoesToHost(false, camera), "feature off: the camera keeps Chromium's default");
  Expect(!PromptGoesToHost(false, kPermissionGeolocation | camera), "feature off: a group with location stays Chromium's");
  Expect(PromptGoesToHost(true, camera | microphone), "feature on: camera and microphone go to the host");
  Expect(PromptGoesToHost(true, notifications), "feature on: notifications go to the host");
  Expect(PromptGoesToHost(true, sensors), "feature on: the last bit CEF 154 defines goes to the host");
  Expect(!PromptGoesToHost(true, 1u << 29), "a bit cmux does not know stays Chromium's");
  Expect(!PromptGoesToHost(true, kPermissionGeolocation | (1u << 30)), "a known bit with an unknown one stays Chromium's");
  Expect(!PromptGoesToHost(true, 0), "no bits: nothing to ask");

  Expect(MediaGoesToHost(true, kMediaDesktopVideo), "feature on: getDisplayMedia video goes to the host");
  Expect(MediaGoesToHost(true, kMediaDesktopVideo | kMediaDesktopAudio), "screen with its audio goes to the host");
  Expect(!MediaGoesToHost(true, kMediaDesktopAudio), "desktop audio alone stays Chromium's (getDisplayMedia needs video)");
  Expect(!MediaGoesToHost(true, kMediaDeviceVideo), "the camera keeps Chromium's devices controller");
  Expect(!MediaGoesToHost(true, kMediaDeviceAudio | kMediaDeviceVideo), "camera and microphone keep Chromium's controller");
  Expect(!MediaGoesToHost(true, kMediaDesktopVideo | kMediaDeviceAudio), "a screen with the microphone stays Chromium's");
  Expect(!MediaGoesToHost(false, kMediaDesktopVideo), "feature off: screen sharing keeps Chromium's picker");

  Expect(MediaAllowed(1, kMediaDesktopVideo | kMediaDesktopAudio) == (kMediaDesktopVideo | kMediaDesktopAudio),
         "Allow grants what was asked");
  Expect(MediaAllowed(2, kMediaDesktopVideo) == 0, "Block grants nothing");
  Expect(MediaAllowed(0, kMediaDesktopVideo) == 0, "no answer grants nothing");

  Expect(FeatureListHas("A,CmuxPermissionPromptsFromData,B", kPermissionPromptsFromDataFeature), "a listed feature");
  Expect(FeatureListHas("CmuxPermissionPromptsFromData", kPermissionPromptsFromDataFeature), "the only entry");
  Expect(FeatureListHas("A, CmuxPermissionPromptsFromData", kPermissionPromptsFromDataFeature), "a space after the comma");
  Expect(FeatureListHas("CmuxPermissionPromptsFromData<Trial", kPermissionPromptsFromDataFeature), "a field trial suffix");
  Expect(FeatureListHas("CmuxPermissionPromptsFromData:x/1", kPermissionPromptsFromDataFeature), "params");
  Expect(!FeatureListHas("CmuxPermissionPromptsFromDataX", kPermissionPromptsFromDataFeature), "a longer name");
  Expect(!FeatureListHas("XCmuxPermissionPromptsFromData", kPermissionPromptsFromDataFeature), "a name ending with it");
  Expect(!FeatureListHas("", kPermissionPromptsFromDataFeature), "an empty list");
  Expect(EveryKindFromFeatureLists("A,CmuxPermissionPromptsFromData", "B"), "enabled and not disabled: on");
  Expect(!EveryKindFromFeatureLists("CmuxPermissionPromptsFromData", "CmuxPermissionPromptsFromData"), "disable wins");
  Expect(!EveryKindFromFeatureLists("A", ""), "not enabled: off");

  Expect(MediaPromptBits(kMediaDesktopVideo) == (int64_t{1} << 35), "media bits sit above bit 32");
  Expect((MediaPromptBits(kMediaDesktopVideo | kMediaDesktopAudio) & kKnownPermissions) == 0,
         "media bits never look like permission bits");

  std::map<int, int> in_use;
  int last = 0;
  Expect(NextPermissionToken(last, in_use) == 1, "the first token is 1");
  in_use[2] = 0;
  Expect(NextPermissionToken(last, in_use) == 3, "a token in use is skipped");
  last = INT32_MAX;
  Expect(NextPermissionToken(last, in_use) == 1, "tokens wrap to 1, never 0");
  in_use[1] = 0;
  last = INT32_MAX - 1;
  Expect(NextPermissionToken(last, in_use) == INT32_MAX, "the largest token is INT32_MAX");
  Expect(NextPermissionToken(last, in_use) == 3, "after wrapping, tokens in use are skipped");

  if (failures != 0) return 1;
  std::puts("permission_prompt_policy: ok");
  return 0;
}
