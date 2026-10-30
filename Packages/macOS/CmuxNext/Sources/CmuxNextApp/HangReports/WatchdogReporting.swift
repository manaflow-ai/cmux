import AppKit
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextHangReports

/// Where the main-thread watchdog's findings go (moved out of `AppDelegate`): each hang still
/// running after 2 s to crash reporting with its stack and to a file per hang; each finished lag
/// spike of 250 ms and up to crash reporting (rate-limited); and both to opt-in hang reports
/// (``HangReportsController``), whose sink does nothing while they are off.
@MainActor
enum WatchdogReporting {
    /// Wires `watchdog` and returns this launch's hang report controller (held by `AppProcessRoot`).
    static func install(_ watchdog: MainThreadWatchdog, services: AppServices) -> HangReportsController {
        let reporter = services.crashReporting.reporter
        let hangReports = HangReportsController.forThisLaunch(
            policy: reporter.policy, folder: SidebarSnapshotFile.buildDirectory(launch: services.environment.launch)
                .appending(path: "HangReports", directoryHint: .isDirectory),
            counts: { @MainActor [weak services] in services.map(WatchdogReporting.counts) ?? .unknown })
        let collector = hangReports.collector
        watchdog.onHang = { hang in
            reporter.reportHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) })
            collector?.noteHang(durationNanos: Self.nanos(hang.duration), addresses: hang.addresses)
        }
        // ~/Library/Logs/<bundle id>/hangs, listed in Debug Settings > Hangs.
        watchdog.episodes = HangFileTunables.recorder(bundleID: Bundle.main.bundleIdentifier)
        let lagSpikes = LagSpikeReporter(reporter: reporter)
        lagSpikes.setContextProvider {
            // The watchdog's run-loop observer on the main run loop reads it; never off main.
            guard Thread.isMainThread else { return [:] }
            return MainActor.assumeIsolated { // main-proof: checked Thread.isMainThread above
                let windows = NSApp.windows
                return ["windows": String(windows.count), "visible_windows": String(windows.filter(\.isVisible).count),
                        "app_active": NSApp.isActive ? "yes" : "no"]
            }
        }
        watchdog.onStall = { record in
            lagSpikes.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses)
            collector?.noteStall(durationNanos: Self.nanos(record.duration), cpuNanos: Self.nanos(record.cpu), addresses: record.addresses)
        }
        return hangReports
    }

    /// What is open now, as buckets: windows, local workspaces, their panes and tabs.
    static func counts(_ services: AppServices) -> CoarseCounts {
        let workspaces = services.daemon.store.workspaces
        let panes = workspaces.flatMap(\.screens).flatMap(\.panes)
        return CoarseCounts(windows: services.windows.controllers.count, workspaces: workspaces.count, panes: panes.count,
                            tabs: panes.reduce(0) { $0 + $1.tabs.count })
    }

    nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }
}
