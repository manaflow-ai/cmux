// CEF subprocess (renderer, GPU, utility, plugin, alerts). The same binary is
// copied into every "<App> Helper (Kind).app" bundle by
// scripts/cmux-next/embed-cef.sh. It enters the sandbox before loading CEF.

#include <pthread/qos.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "helper_signal_policy.h"
#include "page_scheme_registration.h"

namespace {

// The custom schemes, which every process must register the same way as the
// browser process (page_scheme_registration.h), and the quit-signal rule.
class HelperApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  // EXPERIMENT (lane typing-opus-idle, not for merge): CMUX_NEXT_EXP_RENDERER_QOS=1 gives the renderer main thread
  // user-interactive QoS, to see whether an idle renderer runs a key's JS on a parked core at a low clock.
  void OnWebKitInitialized() override {
    const char* asked = getenv("CMUX_NEXT_EXP_RENDERER_QOS");
    if (asked && strcmp(asked, "1") == 0) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  }

  // Runs in BasicStartupComplete, after Chromium reset this process's signals
  // to their defaults (content_main.cc SetupSignalHandlers), so the rule
  // stays: a quit signal from anyone but the browser (pkill or killall by
  // name, Ctrl-C to the app's group) no longer ends this helper before the
  // app, which made Chromium show "uBlock Origin has crashed" while the app
  // quit (helper_signal_policy.h).
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine>) override {
    cmux_shim::InstallHelperQuitSignalPolicy();
  }

  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {
    cmux_shim::RegisterCustomSchemes(registrar);
  }

 private:
  IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  CefRefPtr<CefApp> app = new HelperApp();
  return CefExecuteProcess(main_args, app, nullptr);
}
