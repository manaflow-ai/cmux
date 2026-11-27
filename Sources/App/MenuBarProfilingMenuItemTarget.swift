import AppKit

final class MenuBarProfilingMenuItemTarget: NSObject {
    static let shared = MenuBarProfilingMenuItemTarget()

    @objc func startProfiling(_ sender: NSMenuItem) {
        Task { @MainActor in
            MenuBarProfilingProgressWindowController.shared.startProfiling()
        }
    }
}
