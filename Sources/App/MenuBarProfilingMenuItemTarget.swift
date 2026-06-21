import AppKit

@MainActor
final class MenuBarProfilingMenuItemTarget: NSObject {
    static let shared = MenuBarProfilingMenuItemTarget()

    @objc func startProfiling(_ sender: NSMenuItem) {
        MenuBarProfilingLauncher.start()
    }
}
