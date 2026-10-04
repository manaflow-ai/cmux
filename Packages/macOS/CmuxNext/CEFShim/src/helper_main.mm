// CEF subprocess (renderer, GPU, utility, plugin, alerts). The same binary is
// copied into every "<App> Helper (Kind).app" bundle by
// scripts/cmux-next/embed-cef.sh. It enters the sandbox before loading CEF.

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "opaque_origin_webauthn_guard.h"
#include "page_scheme_registration.h"

namespace {

// The custom schemes, which every process must register the same way as
// the browser process (page_scheme_registration.h), and in renderers the
// interim opaque-origin WebAuthn guard (opaque_origin_webauthn_guard.h).
class HelperApp : public CefApp {
 public:
  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {
    cmux_shim::RegisterCustomSchemes(registrar);
  }

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return guard_; }

 private:
  CefRefPtr<cmux_shim::OpaqueOriginWebAuthnGuard> guard_ = new cmux_shim::OpaqueOriginWebAuthnGuard();
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
