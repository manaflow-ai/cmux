#if DEBUG
import Foundation

/// Drives the DEBUG launch-time XCUITest scaffolding lifted from
/// `applicationDidFinishLaunching`: the diagnostics-probe install plus the
/// after-1s diagnostics write, and the env-gated force-window / update-check /
/// browser-import-hint launch actions.
///
/// The scaffold owns the *orchestration*: the diagnostics-probe install order,
/// the `DispatchQueue.main.asyncAfter` schedule and its exact deadlines, and the
/// `CMUX_UI_TEST_*` environment gates. The diagnostics writer
/// (``DisplayDiagnosticsUITestRecorder``) and the run-loop / turn probes
/// (``RunLoopStallMonitoring`` / ``MainThreadTurnProfiling``) are package types
/// injected at construction, so the scaffold installs and writes them directly.
/// Every action that touches live `NSApp` / update / browser / preferences state
/// is delegated to ``StartupUITestScaffoldDriving``, which the app target
/// conforms.
///
/// Faithfulness: the probe-install order, the `after1s` 1.0s hop, the
/// trigger-update-check 0.25s hop, the force-window 0.25s hop, and the
/// browser-import 0.45 / 0.55 / 0.4s hops reproduce the legacy bodies exactly.
/// The one deliberate delta is that each scheduled action now runs inside a
/// `Task { @MainActor in }` (one additional main-actor turn) to satisfy this
/// package's strict-concurrency isolation, matching the precedent in
/// ``SplitCloseRightScaffoldRunner``; with the 0.25s+ deadlines and the
/// out-of-process XCUITest reading the result through files, the extra turn is
/// unobservable. The legacy closures captured `[weak self]`; the scheduled hops
/// now retain the driver / recorder for the brief delay window instead of
/// bailing on a deallocated delegate, an unobservable difference since the app
/// delegate lives for the whole process.
///
/// Isolation: `@MainActor`, matching the legacy blocks and the driver seam.
@MainActor
public struct StartupUITestScaffold {
    private let recorder: DisplayDiagnosticsUITestRecorder
    private let stallMonitor: any RunLoopStallMonitoring
    private let turnProfiler: any MainThreadTurnProfiling
    private let driver: any StartupUITestScaffoldDriving

    /// Creates a scaffold bound to the live diagnostics writer, the run-loop /
    /// turn probes, and the app-side action driver.
    ///
    /// - Parameters:
    ///   - recorder: The diagnostics writer the app holds (the scaffold writes
    ///     the `didFinishLaunching`, `after1s`, and `afterForceWindow` stages
    ///     directly through it).
    ///   - stallMonitor: The run-loop stall probe installed at launch.
    ///   - turnProfiler: The main-thread turn profiler installed at launch and
    ///     wired into `CmuxTypingTiming`.
    ///   - driver: The app-side conformer supplying the live launch actions.
    public init(
        recorder: DisplayDiagnosticsUITestRecorder,
        stallMonitor: any RunLoopStallMonitoring,
        turnProfiler: any MainThreadTurnProfiling,
        driver: any StartupUITestScaffoldDriving
    ) {
        self.recorder = recorder
        self.stallMonitor = stallMonitor
        self.turnProfiler = turnProfiler
        self.driver = driver
    }

    /// Writes the `didFinishLaunching` diagnostics, installs the typing probes
    /// (pointing `CmuxTypingTiming.turnProfiler` at the injected profiler before
    /// any keystroke can be processed), and schedules the `after1s` diagnostics
    /// write.
    public func installDiagnosticsProbesAndScheduleAfter1s() {
        recorder.write(stage: "didFinishLaunching")
        CmuxTypingTiming.turnProfiler = turnProfiler
        stallMonitor.installIfNeeded()
        turnProfiler.installIfNeeded()
        let recorder = self.recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                recorder.write(stage: "after1s")
            }
        }
    }

    /// Runs the env-gated launch actions in the legacy order: apply update-test
    /// support, log the update-check env, schedule the trigger-update-check,
    /// then (under XCTest only) apply the browser import-hint defaults and
    /// schedule the force-window and browser-import launch actions.
    ///
    /// - Parameters:
    ///   - env: The process environment the scenario is gated by.
    ///   - isRunningUnderXCTest: Whether the app is the XCUITest subject; gates
    ///     the force-window and browser-import-hint actions exactly as the
    ///     legacy block did.
    public func runLaunchScaffolds(environment env: [String: String], isRunningUnderXCTest: Bool) {
        driver.applyUpdateTestSupport()
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
            driver.logUpdateTestEnvironment(trigger: trigger, feed: feed)
        }
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            driver.logTriggerUpdateCheckDetected()
            scheduleMainActor(after: 0.25) { driver in
                driver.performTriggerUpdateCheck()
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window
        // quickly on the VM. If there are no windows shortly after launch, force
        // one so XCUITest can proceed.
        guard isRunningUnderXCTest else { return }
        driver.applyBrowserImportHintDefaults(
            variant: env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_VARIANT"],
            show: env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW"],
            dismissed: env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED"]
        )
        let recorder = self.recorder
        scheduleMainActor(after: 0.25) { driver in
            driver.forceMainWindowAndActivate()
            // On headless CI runners, activate() silently fails (no GUI
            // session). The force-front sequence above keeps windows visible;
            // record the resulting state for the XCUITest.
            recorder.write(stage: "afterForceWindow")
        }
        if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_BLANK_BROWSER"] == "1" {
            scheduleMainActor(after: 0.45) { driver in
                driver.openBlankBrowserAndFocusAddressBar()
            }
        }
        if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_SETTINGS"] == "1" {
            scheduleMainActor(after: 0.55) { driver in
                driver.openBrowserImportSettings()
            }
        }
        if env["CMUX_UI_TEST_BROWSER_IMPORT_AUTO_OPEN"] == "1" {
            scheduleMainActor(after: 0.4) { driver in
                driver.presentBrowserImportDialog()
            }
        }
    }

    /// Schedules `body` on the main queue after `delay`, mirroring the legacy
    /// `DispatchQueue.main.asyncAfter` closures with the same deadline, then runs
    /// `body` on the main actor with the live driver.
    private func scheduleMainActor(
        after delay: TimeInterval,
        _ body: @escaping @MainActor (any StartupUITestScaffoldDriving) -> Void
    ) {
        let driver = self.driver
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                body(driver)
            }
        }
    }
}
#endif
