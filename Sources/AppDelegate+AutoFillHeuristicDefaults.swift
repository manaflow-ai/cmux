import AppKit

extension AppDelegate {
    // On macOS 26, AppKit's NSAutoFillHeuristicController scans focused text
    // input and drives the Safari autofill completion-list XPC view service.
    // Its reconnect-on-interruption path can pin the main thread in a
    // view-service terminate/respawn loop. Registering this fallback mirrors
    // Ghostty's workaround; manual Edit > AutoFill and WebKit autofill remain
    // available because explicit defaults override the registration domain.
    @objc func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }
}
