// CEF helper-process entry point. Every cmux CEF helper bundle runs this
// binary; scripts/embed-cef.sh compiles it and assembles the bundles.
#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"

static int load_cef_framework(void) {
  char executable[4096];
  uint32_t size = sizeof(executable);
  if (_NSGetExecutablePath(executable, &size) != 0) return 0;
  // Helper binary lives at:
  //   App.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<helper>
  // The framework lives at:
  //   App.app/Contents/Frameworks/Chromium Embedded Framework.framework
  char path[4600];
  snprintf(path, sizeof(path),
           "%s/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework",
           dirname(executable));
  void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (handle) {
    // Declare the API version before any other CEF call.
    cef_api_hash(CEF_API_VERSION, 0);
    return 1;
  }
  if (!handle) {
    fprintf(stderr, "helper dlopen failed: %s\n", dlerror());
    return 0;
  }
  return 1;
}

int main(int argc, char *argv[]) {
  if (!load_cef_framework()) return 1;
  cef_main_args_t args = {argc, argv};
  return cef_execute_process(&args, NULL, NULL);
}
