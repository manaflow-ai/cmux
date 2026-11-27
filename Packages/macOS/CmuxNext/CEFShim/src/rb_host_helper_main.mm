// Chromium subprocess (renderer, GPU, utility, plugin, alerts) of the remote
// browser host, Contents/Helpers/cmux-remote-browser-host.app. The same binary
// is copied into its five "cmux-remote-browser-host Helper (Kind).app" bundles
// by scripts/cmux-next/embed-remote-browser-host.sh (rbh_write_bundle), the way
// helper_main.mm serves the app's own helpers.
//
// It does exactly what the host binary does when CEF starts it with --type=
// (rb_shim_run in cmux-tui/crates/cmux-remote-browser-host/csrc/rb_shim.mm):
// load CEF as a helper and run CefExecuteProcess with no CefApp. The host
// registers no custom schemes and runs with no_sandbox, so there is no
// scheme registration and no sandbox context here. Before this, each helper
// was a copy of the 3.6 MB host binary (cmux#42190).

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
