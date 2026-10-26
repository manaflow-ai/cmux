import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextHangReports
import CmuxNextWakeups

/// Where the main-thread watchdog's findings go (moved out of `AppDelegate`): each hang still
/// running after 2 s to crash reporting with its stack and to a file per hang; each finished lag
/// spike of 250 ms and up to crash reporting (rate-limited); and both to opt-in hang reports
/// (``HangReportsController``), whose sink does nothing while they are off; with the main thread's phase
/// (`main_thread_phase`, `cef_pump`). The blocking detector's new call sites go to ``BlockingReportSink``.
@MainActor
enum WatchdogReporting {
    /// Wires `watchdog` and returns this launch's hang report controller (held by `AppProcessRoot`).
    static func install(_ watchdog: MainThreadWatchdog, services: AppServices) -> HangReportsController {
        let reporter = services.crashReporting.reporter
        let memory = HiddenWorkspaceMemory(
            work: services.work, mainWork: services.mainWork,
            capture: { [weak services] in services.map(WatchdogReporting.hiddenWorkspaceCapture) ?? .init() },
            rendererPIDs: { Dictionary(AppProcesses.tabRendererClients().map { pid, client in (client, pid) }, uniquingKeysWith: { first, _ in first }) })
        let hangReports = HangReportsController.forThisLaunch(
            policy: reporter.policy, folder: SidebarSnapshotFile.buildDirectory(launch: services.environment.launch)
                .appending(path: "HangReports", directoryHint: .isDirectory),
            counts: { @MainActor [weak services] in services.map(WatchdogReporting.counts) ?? .unknown },
            watchdog: watchdog, input: services.inputTap, events: services.appEvents, memory: memory)
        let collector = hangReports.collector
        // Replays the sites the detector recorded before this point (BlockingDetector.install).
        services.blocking.install(sink: BlockingReportSink(collector: collector, nonFatal: .init(
            consented: { reporter.isStarted },
            send: { reporter.captureNonFatal($0.message, type: $0.type, fingerprint: $0.fingerprint, tags: $0.tags, extra: $0.extra) })))
        watchdog.onHang = { hang in
            reporter.reportHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) }, phase: hang.phase)
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
            lagSpikes.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses, phase: record.details["phase"]?.stringValue)
            collector?.noteStall(durationNanos: Self.nanos(record.duration), cpuNanos: Self.nanos(record.cpu), addresses: record.addresses)
        }
        return hangReports
    }

    /// What is open now, as buckets: windows, local workspaces, their panes and tabs; and the background lanes'
    /// user-blocking queue-wait p99 (relaxed atomic loads, no lock), which a schema-3 report carries.
    static func counts(_ services: AppServices) -> CoarseCounts {
        let workspaces = services.daemon.store.workspaces
        let panes = workspaces.flatMap(\.screens).flatMap(\.panes)
        return CoarseCounts(windows: services.windows.controllers.count, workspaces: workspaces.count, panes: panes.count,
                            tabs: panes.reduce(0) { $0 + $1.tabs.count },
                            userBlockingWaitP99Nanos: services.work.userBlockingQueueWaitP99Nanos)
    }

    /// Every mounted browser tab with its workspace and renderer frames, and the workspaces with one that no
    /// window shows (task 061). O(browser tabs): each tab's workspace from the stores' tab index, one shim call
    /// per Chromium tab. A page of another engine has unknown frames, so its hidden workspace's sample is unclear.
    static func hiddenWorkspaceCapture(_ services: AppServices) -> HiddenWorkspaceMemory.Capture {
        let shown = Set(services.windows.controllers.flatMap { $0.onScreenContents.map(\.workspace.id) })
        var hidden = Set<String>()
        let tabs = services.cache.browsers.map { key, entry in
            let workspace = services.workspaceID(ofTab: key)
            if let workspace, !shown.contains(workspace) { hidden.insert(workspace) }
            return HiddenWorkspaceMemory.Placement(workspace: workspace, rendererFrames: (entry.tab as? CEFTab)?.rendererFrames)
        }
        return HiddenWorkspaceMemory.Capture(tabs: tabs, hiddenWorkspaces: hidden)
    }

    nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }
}
