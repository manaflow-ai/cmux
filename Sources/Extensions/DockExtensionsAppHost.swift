import AppKit
import CmuxDockExtensions

/// App-side ``DockExtensionsHost``: opens extension panes in the active
/// window's Dock and enables/reveals the Dock beta feature on install (the
/// locked product decision — installing an extension turns the Dock on).
@MainActor
final class DockExtensionsAppHost: DockExtensionsHost {
    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func openExtensionPane(_ request: DockExtensionPaneOpenRequest) -> Bool {
        guard let appDelegate = AppDelegate.shared,
              let context = appDelegate.preferredRegisteredMainWindowContext(
                  preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            return false
        }
        // Opening a pane implies the Dock: make sure the availability gate
        // passes before the mode switch below.
        enableDockBetaFlagIfNeeded()
        let dock = context.windowDockStore()
        guard dock.openExtensionPane(
            controlId: request.controlId,
            title: request.title,
            iconSystemName: request.iconSystemName,
            shellCommand: request.shellCommand,
            workingDirectory: request.workingDirectory,
            environment: request.environment
        ) != nil else {
            return false
        }
        appDelegate.focusRightSidebarInActiveMainWindow(
            mode: .dock,
            focusFirstItem: false,
            preferredWindow: context.window
        )
        return true
    }

    func activateDockForExtensions() {
        enableDockBetaFlagIfNeeded()
        AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .dock,
            focusFirstItem: false
        )
    }

    private func enableDockBetaFlagIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey) {
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        }
    }
}
