import AppKit

extension AppDelegate {
    // On macOS 26, AppKit's NSAutoFillHeuristicController scans focused text
    // input for autofillable content (one-time codes, credentials) and drives
    // the Safari autofill completion-list XPC view service. In a terminal this
    // burns main-thread CPU, and via its shouldReconnectOnInterruption: hook it
    // can pin a core in a completion-list view-service terminate/respawn loop
    // (https://github.com/manaflow-ai/cmux/issues/5946). Ghostty upstream
    // registers the same default for the same reason. Manual autofill via
    // Edit > AutoFill and WebKit's own browser-pane autofill still work.
    @objc func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }
}
