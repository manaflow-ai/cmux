import AppKit
#if CMUX_BENCH_HOOKS
import CmuxNextFeatures
import os
#endif

/// The process root (plans/cmux-next/crash-elimination.md, P1b): the app's one
/// `AppServices`, held here for the life of the process. Many service objects
/// keep an `unowned` back-reference to `AppServices`; they are safe because their
/// owner is never freed while the process runs, and this holder is what makes
/// that true by choice (crash-allowlist.json entries: "owner is the explicit
/// process root AppServices"). The launch adopts the services right after making
/// them. Tests that build their own services do not adopt them.
@MainActor
final class AppProcessRoot {
    static let shared = AppProcessRoot()

    /// The adopted services; never released once set.
    private(set) var services: AppServices?

    /// Holds `services` for the rest of the process. A bench build also logs the perf lab features and, with
    /// `perfLabCanary` on, puts the canary's 2 ms spin in front of the key-down dispatcher the services set.
    func adopt(_ services: AppServices) {
        self.services = services
        #if CMUX_BENCH_HOOKS
        let report = PerfLabFeatureReport(services.features)
        Logger(subsystem: "com.cmuxterm.app.next", category: "perf-lab").notice("\(report.line, privacy: .public)")
        if report.canary.isEnabled, let app = NSApp as? CmuxApplication, let dispatch = app.keyDownInterceptor {
            app.keyDownInterceptor = PerfLabKeySpin(clock: ContinuousClock()).delaying(dispatch)
        }
        #endif
    }

    /// This launch's opt-in hang reports (`WatchdogReporting`); nil in tests and before launch.
    private(set) var hangReports: HangReportsController?

    /// Holds `controller` for the rest of the process.
    func adopt(hangReports controller: HangReportsController) {
        hangReports = controller
    }
}
