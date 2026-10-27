#if CMUX_BENCH_HOOKS
import CmuxNextFeatures
import os
#endif

/// The process root (plans/cmux-next/crash-elimination.md, P1b): the app's one
/// `AppServices`, held here for the life of the process, as Chrome keeps its
/// process-lifetime objects in `base::NoDestructor` (base/no_destructor.h). The
/// objects under it (its services, windows, panes and page providers) hold it
/// strongly: the root is never freed, so that reference adds no lifetime, and no
/// read of it can find it gone (p10-stability-091; an `unowned` one traps then).
/// The launch adopts the services right after making them. Tests that build
/// their own services do not adopt them; those services then stay for the rest
/// of the test process, as bound actions (`AppActionContext`) already kept them.
@MainActor
final class AppProcessRoot {
    static let shared = AppProcessRoot()

    /// The adopted services; never released once set.
    private(set) var services: AppServices?

    /// Holds `services` for the rest of the process. A bench build also logs the perf lab features' values and
    /// sources (the kill probe's proof; `PerfLabCanaryKeyDown` runs the canary's spin).
    func adopt(_ services: AppServices) {
        self.services = services
        #if CMUX_BENCH_HOOKS
        let report = PerfLabFeatureReport(services.features)
        Logger(subsystem: "com.cmuxterm.app.next", category: "perf-lab").notice("\(report.line, privacy: .public)")
        #endif
    }

    /// This launch's opt-in hang reports (`WatchdogReporting`); nil in tests and before launch.
    private(set) var hangReports: HangReportsController?

    /// Holds `controller` for the rest of the process.
    func adopt(hangReports controller: HangReportsController) {
        hangReports = controller
    }
}
