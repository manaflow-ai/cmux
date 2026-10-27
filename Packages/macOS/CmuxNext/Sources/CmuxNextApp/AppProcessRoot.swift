import CmuxNextDaemonService
import struct CmuxSafeConcurrency.OwnerReference
#if CMUX_BENCH_HOOKS
import CmuxNextFeatures
import os
#endif

/// The process root (plans/cmux-next/crash-elimination.md, P1b): the app's one
/// `AppServices`, held here for the life of the process. The objects under it
/// never own it back (p10-stability-091): the services, windows, panes and page
/// providers it builds keep a non-owning reference, as Chromium's back-pointers
/// are `raw_ptr` and never keep their owner alive. The few whose lifetime is
/// structural keep `unowned`, each with a `lifetime:` reason naming this holder
/// in crash-allowlist.json; the rest hold an `AppServicesReference`, which reports
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

/// A service's non-owning reference back to the app's `AppServices`, which owns it (p10-stability-091): an
/// `OwnerReference`, so a read after the services are gone reports once per site and gives nil, and the caller
/// refuses (an action throws ``closing``) or does nothing. In the app `AppProcessRoot` holds the services until exit,
/// so a miss is a bug; a test that builds its own services frees them, and every service under them, when it lets
/// them go.
nonisolated struct AppServicesReference: Sendable {
    /// What an action refuses with when the services are gone.
    static var closing: ActionFailure { ActionFailure(message: closingReason) }
    /// The refusal's text, for a call that answers with a reason instead of throwing.
    static var closingReason: String { RefusalStrings.appClosing }

    private let reference: OwnerReference<AppServices>

    init(_ services: AppServices) {
        reference = OwnerReference(services, invariant: "app-services-outlive-their-services")
    }

    /// The services, or nil after reporting this site's first miss of the launch.
    func resolve(fileID: StaticString = #fileID, line: UInt = #line) -> AppServices? {
        reference.resolve(fileID: fileID, line: line)
    }
}
