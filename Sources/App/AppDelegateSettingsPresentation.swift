import AppKit

/// The Settings-open entrypoints shared by the app menu, ⌘,, the command
/// palette, help commands, and the menu-bar extra. Split out of
/// `AppDelegate.swift` (file-length budget) alongside the AppKit-owned
/// Settings window lifecycle (https://github.com/manaflow-ai/cmux/issues/7777).
extension AppDelegate {
    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        // Test seam only; a substitute presenter must still report a
        // `SettingsWindowShowResult`, so there is no alternate path that can
        // claim success without a verified window (the #7775 failure shape).
        presentSettingsWindow: (@MainActor (SettingsNavigationTarget?) -> SettingsWindowShowResult)? = nil,
        // Fallback for a substitute presenter that could only order a window
        // while the app remained hidden. A normally presented window already
        // has exact activation and key ordering owned by the presenter.
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) {
#if DEBUG
        cmuxDebugLog("settings.open.present path=appkitWindow")
#endif
        let present = presentSettingsWindow
            ?? { SettingsWindowPresenter.show(navigationTarget: $0) }
        switch present(navigationTarget) {
        case .failed:
            // The presenter already logged the loud failure diagnostics;
            // surface the failed menu/⌘, action instead of silently activating.
            NSSound.beep()
            return
        case .orderedWhileAppHidden:
            // Only this result still owes activation. Running another
            // `.activateAllWindows` after `.presented` can reorder a main cmux
            // window above the Settings window the presenter just keyed.
            activateApplication()
#if DEBUG
            cmuxDebugLog("settings.open.present activate=fallbackHiddenApp")
#endif
        case .presented:
            // SettingsWindowPresenter activated the app, then made the exact
            // Settings window key and frontmost. Preserve that final ordering.
            break
        }
#if DEBUG
        cmuxDebugLog("settings.open.present complete=1")
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
