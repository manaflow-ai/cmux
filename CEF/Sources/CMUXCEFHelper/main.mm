// CMUXCEFHelper main — entry point for the GPU / utility / network /
// alerts / plugin helper processes. CEF spawns one of these for each
// non-renderer subprocess role; the executable name is what shows up in
// Activity Monitor.
//
// The helper binary is compiled once and embedded into cmux.app as
// multiple .app bundles (WebView Helper.app, WebView Helper (GPU).app,
// WebView Helper (Plugin).app, WebView Helper (Alerts).app — all sharing
// the same Mach-O binary; the bundle name carries the role).
//
// This file intentionally has zero non-CEF dependencies. Any logic
// belongs in the browser process, which is the only place we can
// reason about cmux state.

#import "../CMUXCEFBridge/include/CMUXCEFBridge.h"

#include "include/cef_app.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int code = [CMUXCEFEngineBridge executeSubprocessIfNeededWithArgc:argc argv:argv];
        if (code >= 0) {
            return code;
        }
        // This binary is only run as a CEF helper. If we somehow land here
        // (no --type= argument), exit with an error so the misuse is
        // visible.
        fprintf(stderr, "CMUXCEFHelper: refusing to run as the browser process\n");
        return 2;
    }
}
