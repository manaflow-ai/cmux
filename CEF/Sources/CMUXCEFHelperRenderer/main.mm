// CMUXCEFHelperRenderer main — entry point for renderer subprocesses.
// One process per page (or per site, depending on Chromium's process
// isolation policy). cmux ships this as a separate executable because
// renderer helpers need their own entitlement profile (JIT + unsigned
// executable memory) distinct from the other utility helpers.
//
// Same shape as CMUXCEFHelper/main.mm — execute the CEF subprocess
// loop and exit. CEF's libcef takes care of CefRenderProcessHandler
// installation when the right hooks are registered on the CefApp
// passed to CefExecuteProcess.

#import "../CMUXCEFBridge/include/CMUXCEFBridge.h"

#include "include/cef_app.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int code = [CMUXCEFEngineBridge executeSubprocessIfNeededWithArgc:argc argv:argv];
        if (code >= 0) {
            return code;
        }
        fprintf(stderr, "CMUXCEFHelperRenderer: refusing to run as the browser process\n");
        return 2;
    }
}
