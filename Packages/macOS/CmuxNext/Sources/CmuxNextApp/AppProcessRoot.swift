import struct CmuxSafeConcurrency.OwnerReference
#if CMUX_BENCH_HOOKS
import CmuxNextFeatures
import os
#endif

/// The process root (plans/cmux-next/crash-elimination.md, P1b): the app's one
/// `AppServices`, held here for the life of the process. The objects under it
/// never own it back: the services, windows, panes and page
/// providers it builds keep a non-owning reference, as Chromium's back-pointers
/// are `raw_ptr` and never keep their owner alive. The few whose lifetime is
/// structural keep `unowned`, each with a `lifetime:` reason naming this holder
/// in crash-allowlist.json; the rest hold an `OwnerReference<AppServices>`, which reports
/// and refuses a call that comes after the services are gone. The launch adopts
/// the services right after making them. Tests that build their own services do
/// not adopt them, so those services, and everything under them, go when the
/// test lets them go.
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

extension OwnerReference where Owner == AppServices {
    /// A service's non-owning reference back to the app's `AppServices`, which owns it: a read
    /// after the services are gone reports once per site and gives nil, and the caller refuses
    /// (``CmuxNextDaemonService/ActionFailure/appClosing``) or does nothing.
    init(services: AppServices) {
        self.init(services, invariant: "app-services-outlive-their-services")
    }
}
