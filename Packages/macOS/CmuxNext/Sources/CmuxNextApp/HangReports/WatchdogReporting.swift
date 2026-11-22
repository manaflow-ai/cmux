import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextHangReports

/// Where the main-thread watchdog's findings go (moved out of `AppDelegate`): each hang still
/// running after 2 s to crash reporting with its stack (budgeted, `MainThreadHangReporter`) and to
/// a file per hang; each finished lag spike of 250 ms and up to crash reporting (rate-limited);
/// every stall as hourly counts (`CrashReporter.stallSummary`); and both to opt-in hang reports
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
        watchdog.onHang = { [hangs = MainThreadHangReporter(reporter: reporter)] hang in
            hangs.noteHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) })
            collector?.noteHang(duration: hang.duration, addresses: hang.addresses)
        }
        reporter.followTeamMembers(ObservationStream { [weak auth = services.cloud.auth] in auth.flatMap { auth in auth.user.flatMap {
            CrashReportIdentity.member(userID: auth.isSignedIn ? $0.id : nil, name: $0.displayName, email: $0.primaryEmail, teamIDs: auth.teams.map(\.id)) } } })
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
            collector?.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses)
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
}
