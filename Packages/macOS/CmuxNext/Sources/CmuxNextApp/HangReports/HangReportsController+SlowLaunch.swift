import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextHangReports
import Foundation

/// The slow-launch trace's side of the hang reports controller (p08-startup-111): which launches keep the ring, and
/// the hand-off of a slow launch's trace to the collector.
extension HangReportsController {
    /// Whether a build of `channel` may send hang reports at all: NIGHTLY, or DEV with ``devOptInKey``, never in a
    /// test process.
    static func mayReport(channel: CrashReportingPolicy.Channel?, environment: [String: String]) -> Bool {
        let devOptIn = channel == .dev && environment[devOptInKey] == "1"
        return (channel == .nightly || devOptIn) && !CrashReportingPolicy.isTestProcess(environment)
    }

    /// Whether this launch keeps the slow-launch ring (read in `main()` before the first mark): a build that may send
    /// hang reports (``mayReport(channel:environment:)``) on a Mac with the consent record. A build that never sends
    /// reads no defaults. Whether reports carry the trace is known only once the features resolve; a launch whose
    /// reports do not frees the ring then (``SlowLaunchReporting``).
    static func recordsSlowLaunch(bundleID: String? = Bundle.main.bundleIdentifier, isDebugBuild: Bool = ControlService.isDebugBuild,
                                  defaults: @autoclosure () -> UserDefaults = .standard,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let channel = CrashReportingPolicy(bundleID: bundleID, shortVersion: "0", build: "0", isDebugBuild: isDebugBuild, telemetryOptIn: false,
                                           managedDisablesTelemetry: false, processEnvironment: environment).channel
        return mayReport(channel: channel, environment: environment) && defaults().object(forKey: consentKey) is Date
    }

    /// Whether this launch's reports carry a slow launch's trace (``HangReport/launchTrace``): the builder sends one
    /// (features `hangReportsSchema3` and `hangReportsLaunchTrace`).
    var sendsLaunchTrace: Bool { collector?.keepsLaunchTrace ?? false }

    /// A launch that missed its first-frame budget (``SlowLaunchReporting``): to the collector once reports are on,
    /// dropped when they are off. Before the setting's first decision it waits (``LaunchTraceHandoff``), so a launch
    /// that completes before the settings load still reports.
    func noteLaunchTrace(_ trace: HangReport.LaunchTrace) {
        guard let collector, collector.keepsLaunchTrace else { return }
        launchTraces.note(trace, collector: collector)
    }
}

/// A slow launch's trace on its way to the collector: the collector drops what it is handed while reports are off,
/// and at `startup_complete` the setting may not have been read yet, so the trace waits for the first decision.
@MainActor
final class LaunchTraceHandoff {
    private var decided = false
    private var pending: HangReport.LaunchTrace?

    /// Hands `trace` to `collector` once reports were decided; before that, keeps it (the newest one).
    func note(_ trace: HangReport.LaunchTrace, collector: HangReportCollector) {
        if decided { collector.noteLaunchTrace(trace) } else { pending = trace }
    }

    /// Reports were turned on or off: a waiting trace goes to `collector` when on, and is dropped either way after.
    func decide(_ on: Bool, collector: HangReportCollector) {
        decided = true
        if on, let pending { collector.noteLaunchTrace(pending) }
        pending = nil
    }
}
