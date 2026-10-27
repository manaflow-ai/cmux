// Checks the Chromium Host's framework read (src/host_framework_prefetch.h,
// task p01-process-101) on a fake framework folder: the binary first, then
// the top-level Resources files in name order, locale folders left out; every
// byte read once; a missing file skipped. That the app maps no framework
// page in host mode is process-model-census.py's framework row (fleet).
// Run by scripts/cmux-next/tests/chromium-host-prefetch.test.sh.
#include <sys/stat.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "host_framework_prefetch.h"

namespace {

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

void Write(const std::string& path, size_t bytes) {
  FILE* file = std::fopen(path.c_str(), "wb");
  if (!file) {
    std::fprintf(stderr, "cannot write %s\n", path.c_str());
    std::exit(2);
  }
  const std::string block(4096, 'x');
  for (size_t written = 0; written < bytes; written += block.size()) {
    std::fwrite(block.data(), 1, std::min(block.size(), bytes - written), file);
  }
  std::fclose(file);
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <scratch dir>\n", argv[0]);
    return 2;
  }
  const std::string framework = std::string(argv[1]) + "/Chromium Embedded Framework.framework";
  const std::string resources = framework + "/Resources";
  mkdir(framework.c_str(), 0755);
  mkdir(resources.c_str(), 0755);
  mkdir((resources + "/en.lproj").c_str(), 0755);
  const size_t binary = (3 << 20) + 123;  // several 1 MiB chunks, not a multiple of one
  Write(framework + "/Chromium Embedded Framework", binary);
  Write(resources + "/resources.pak", 5000);
  Write(resources + "/icudtl.dat", 70000);
  Write(resources + "/v8_context_snapshot.arm64.bin", 0);
  Write(resources + "/en.lproj/locale.pak", 9000);

  const std::vector<std::string> want = {framework + "/Chromium Embedded Framework", resources + "/icudtl.dat",
                                         resources + "/resources.pak",
                                         resources + "/v8_context_snapshot.arm64.bin"};
  Check(cmux_host::FrameworkPrefetchFiles(framework) == want,
        "the binary, then the top-level Resources files in name order, no locale folder");

  const cmux_host::FrameworkPrefetchReport report = cmux_host::PreReadFramework(framework);
  Check(report.bytes == static_cast<int64_t>(binary + 5000 + 70000), "every byte of every file, once");
  Check(report.files == 4, "four files read to their end (the empty one too)");

  const cmux_host::FrameworkPrefetchReport missing =
      cmux_host::PreReadFiles({framework + "/nonexistent", resources + "/resources.pak"});
  Check(missing.files == 1 && missing.bytes == 5000, "a file that does not open is skipped");

  Check(cmux_host::FrameworkPrefetchFiles(std::string(argv[1]) + "/none.framework").size() == 1,
        "no Resources folder: the binary alone");

  if (failures) return 1;
  std::printf("host_framework_prefetch_test: ok\n");
  return 0;
}
