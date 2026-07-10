import AppKit

/// The Settings-open entrypoints shared by the app menu, ⌘,, the command
/// palette, help commands, and the menu-bar extra. Split out of
/// `AppDelegate.swift` (file-length budget) alongside the AppKit-owned
/// Settings window lifecycle (https://github.com/manaflow-ai/cmux/issues/7777).
extension AppDelegate {
    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: (@MainActor (SettingsNavigationTarget?) -> Void)? = nil,
        // The legacy body also passed .activateIgnoringOtherApps; the option
        // is deprecated and documented as a no-op on macOS 14+ (this target's
        // minimum), so dropping it is behavior-neutral.
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) {
#if DEBUG
        cmuxDebugLog("settings.open.present path=appkitWindow")
#endif
        if let showFallbackSettingsWindow {
            showFallbackSettingsWindow(navigationTarget)
        } else if case .failed = SettingsWindowPresenter.show(navigationTarget: navigationTarget) {
            // The presenter already logged the loud failure diagnostics;
            // surface the failed menu/⌘, action instead of silently activating.
            NSSound.beep()
            return
        }
        activateApplication()
#if DEBUG
        cmuxDebugLog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        cmuxDebugLog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }
}
