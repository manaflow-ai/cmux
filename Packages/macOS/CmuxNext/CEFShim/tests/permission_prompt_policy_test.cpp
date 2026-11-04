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
  constexpr uint32_t camera = 1u << 2;

  Expect(PromptGoesToHost(kPermissionGeolocation), "location goes to the host");
  Expect(!PromptGoesToHost(camera), "the camera keeps Chromium's default");
  Expect(!PromptGoesToHost(kPermissionGeolocation | camera), "a group with location stays Chromium's");
  Expect(!PromptGoesToHost(0), "no bits: nothing to ask");

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
