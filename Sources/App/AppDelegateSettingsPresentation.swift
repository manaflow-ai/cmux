import AppKit

/// The Settings-open entrypoints shared by the app menu, ⌘,, the command
/// palette, help commands, and the menu-bar extra. Split out of
/// `AppDelegate.swift` (file-length budget) alongside the AppKit-owned
/// Settings window lifecycle (https://github.com/manaflow-ai/cmux/issues/7777).
extension AppDelegate {
    @MainActor
    @discardableResult
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        // Test seam only; a substitute presenter must still report a
        // `SettingsWindowShowResult`, so there is no alternate path that can
        // claim success without a verified window (the #7775 failure shape).
        presentSettingsWindow: (@MainActor (SettingsNavigationTarget?) -> SettingsWindowShowResult)? = nil,
        // The legacy body also passed .activateIgnoringOtherApps; the option
        // is deprecated and documented as a no-op on macOS 14+ (this target's
        // minimum), so dropping it is behavior-neutral.
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) -> SettingsWindowShowResult {
#if DEBUG
        cmuxDebugLog("settings.open.present path=appkitWindow")
#endif
        let present = presentSettingsWindow
            ?? { SettingsWindowPresenter.show(navigationTarget: $0) }
        let result = present(navigationTarget)
        if case .failed = result {
            // The presenter already logged the loud failure diagnostics;
            // surface the failed menu/⌘, action instead of silently activating.
            NSSound.beep()
            return result
        }
        activateApplication()
#if DEBUG
        cmuxDebugLog("settings.open.present activate=1")
#endif
        return result
    }

    @MainActor
    @discardableResult
    func openPreferencesWindow(
        debugSource: String,
        navigationTarget: SettingsNavigationTarget? = nil
    ) -> SettingsWindowShowResult {
#if DEBUG
        cmuxDebugLog("settings.open.request source=\(debugSource)")
#endif
        return Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }
}
