#if DEBUG
/// The app-side action seam for ``StartupUITestScaffold``.
///
/// ``StartupUITestScaffold`` owns the launch-time UI-test orchestration lifted
/// from `applicationDidFinishLaunching`: the `CMUX_UI_TEST_*` environment gates,
/// the `DispatchQueue.main.asyncAfter` schedule, and the diagnostics-probe
/// install order. The actions it sequences drive `NSApp` windows, the Sparkle
/// update controller and its log, the browser import-hint `UserDefaults`
/// overrides, the browser address bar, the preferences window, and the
/// browser-data import dialog. That live state lives in the app target and
/// cannot cross the package boundary, so the app conforms this protocol and the
/// scaffold calls back into it for each gated action.
///
/// The seam is intentionally `#if DEBUG` only: these launch hooks exist purely
/// for XCUITest instrumentation and are compiled out of release builds, matching
/// the legacy `#if DEBUG` blocks they were extracted from.
///
/// Isolation: `@MainActor`, because every action reads and mutates main-actor
/// app / AppKit state. `AnyObject` so the scaffold can hold and capture the
/// conformer weakly across its scheduled hops, exactly as the legacy
/// `[weak self]` closures did.
@MainActor
public protocol StartupUITestScaffoldDriving: AnyObject {
    /// Applies the `UpdateTestSupport` mock-feed configuration once at launch.
    func applyUpdateTestSupport()

    /// Logs the resolved update-check UI-test environment (`CMUX_UI_TEST_MODE`).
    func logUpdateTestEnvironment(trigger: String, feed: String)

    /// Logs that the trigger-update-check scenario was detected, synchronously,
    /// before the scheduled check runs.
    func logTriggerUpdateCheckDetected()

    /// Runs the scheduled trigger-update-check body: logs the live window list,
    /// runs the mock feed check, and falls through to a real update check when
    /// the mock did not handle it.
    func performTriggerUpdateCheck()

    /// Writes the browser import-hint `UserDefaults` overrides for the supplied
    /// raw environment values (each `nil` when its env var is unset).
    func applyBrowserImportHintDefaults(variant: String?, show: String?, dismissed: String?)

    /// Opens a main window if none exist, moves it to the UI-test target
    /// display, activates the app, and force-orders every window front.
    func forceMainWindowAndActivate()

    /// Opens a blank browser tab and focuses its address bar (inserted at end).
    func openBlankBrowserAndFocusAddressBar()

    /// Opens the preferences window on the browser import settings section.
    func openBrowserImportSettings()

    /// Presents the browser-data import dialog.
    func presentBrowserImportDialog()
}
#endif
