import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHangReports
import CmuxNextTrace
import CmuxNextWakeups

/// Where the main-thread watchdog's findings go (moved out of `AppDelegate`): each hang still
/// running after 2 s to crash reporting with its stack and to a file per hang; each finished lag
/// spike of 250 ms and up to crash reporting (rate-limited); and both to opt-in hang reports
/// (``HangReportsController``), whose sink does nothing while they are off, as each committed key's `key.frame`
/// time (`AppServices.inputFrameSignposts`); with the main thread's phase (`main_thread_phase`, `cef_pump`)
/// and `hang.cef` in the CEF pump. The blocking detector's new call sites go to ``BlockingReportSink``.
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
            watchdog: watchdog, input: services.inputTap, events: services.appEvents, memory: memory,
            work: services.work, mainWork: services.mainWork,
            metricsFolder: TraceBlackBoxFileSteps.appDirectory(bundleID: Bundle.main.bundleIdentifier),
            daemonPID: { [weak services] in services?.daemon.identity?.pid },
            wireSchema: .written(serverAcceptsSchema3: services.features.isEnabled(.hangReportsSchema3)),
            features: { [features = FeatureFlagsPage.report(services.features, tunables: TunableStore.shared)] in
                HangReport.FeatureState(features.fieldState)
            })
        let collector = hangReports.collector
        // The drain queue is a hang-watched lane for the process's life (Compat cannot see the watch). Set before
        // the sink: both are drain-queue jobs in call order, so the replay below runs inside the watch.
        if services.blocking.isCompiledIn {
            let drain = HangWatchedLane("blocking.drain", deadline: BlockingDetector.drainHangDeadline, on: TraceRuntime.shared.hangWatch)
            services.blocking.watchDrain { job in drain.run(job) }
        }
        // Replays the sites the detector recorded before this point (BlockingDetector.install).
        services.blocking.install(sink: BlockingReportSink(collector: collector, nonFatal: .init(
            consented: { reporter.isStarted },
            send: { reporter.captureNonFatal($0.message, type: $0.type, fingerprint: $0.fingerprint, tags: $0.tags, extra: $0.extra) })))
        watchdog.onHang = { hang in
            reporter.reportHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) },
                                phase: hang.phase, cef: hang.cef, attribution: .init(owner: hang.attribution.owner, taskClass: hang.attribution.taskClass, location: hang.attribution.location, turnNanos: hang.attribution.turnNanos))
            collector?.noteHang(durationNanos: Self.nanos(hang.duration), addresses: hang.addresses, task: HangSample.MainTask(owner: hang.attribution.owner, taskClass: hang.attribution.taskClass))
        }
        // A watched thread still in its hang-watch scope 2 s past its budget (p09-observability-068): a crash report
        // tagged hang.thread and a hang-report entry, at most once per registration name per report interval.
        watchdog.onThreadHang = { hang in
            reporter.reportThreadHang(ThreadHangEvent(thread: hang.name, threadKind: hang.kindName, threadName: hang.threadName,
                                                      overrun: hang.overrun, addresses: hang.addresses))
            collector?.noteThreadHang(durationNanos: Self.nanos(hang.overrun), addresses: hang.addresses,
                                      thread: HangSample.WatchedThread(name: hang.name, kind: hang.kindName))
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
            lagSpikes.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses, phase: record.details["phase"]?.stringValue, cef: record.details["cef"]?.boolValue == true)
            collector?.noteStall(durationNanos: Self.nanos(record.duration), cpuNanos: Self.nanos(record.cpu), addresses: record.addresses)
        }
        // A slow key frame takes the black box (one compare, then one atomic load while reports are off).
        if let collector { services.inputFrameSignposts.committedKey = { collector.noteKeyFrame(durationMicros: $0) } }
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

    /// Every mounted browser tab with its workspace and renderer frames, the workspaces with one that no window
    /// shows, and every Chromium browser's frames per renderer (task 061). O(browser tabs + frames): each tab's
    /// workspace from the stores' tab index, one shim call for all frames. A live page of another engine has
    /// unknown frames, so its hidden workspace's sample is unclear.
    static func hiddenWorkspaceCapture(_ services: AppServices) -> HiddenWorkspaceMemory.Capture {
        let shown = Set(services.windows.controllers.flatMap { $0.onScreenContents.map(\.workspace.id) })
        // An engine not built yet runs no Chromium: no browser, no frame.
        let frames: CEFRendererFrames? = if let engine = services.cache.chromium.built { engine.rendererFrames } else { CEFRendererFrames([]) }
        var hidden = Set<String>()
        let tabs = services.cache.browsers.map { key, entry in
            let workspace = services.workspaceID(ofTab: key)
            if let workspace, !shown.contains(workspace) { hidden.insert(workspace) }
            return HiddenWorkspaceMemory.Placement(workspace: workspace, rendererFrames: rendererFrames(of: entry.tab, in: frames))
        }
        return HiddenWorkspaceMemory.Capture(tabs: tabs, hiddenWorkspaces: hidden, rendererFrameTotals: frames?.totals ?? [:])
    }

    /// `tab`'s frames per renderer from `frames`: none for a page with no engine page (hibernated, deferred),
    /// which holds no renderer memory; nil (unknown) for a live page of another engine and when `frames` is
    /// unknown (host mode).
    static func rendererFrames(of tab: any BrowserTab, in frames: CEFRendererFrames?) -> [(clientID: Int32, frames: Int)]? {
        switch tab {
        case let tab as CEFTab: frames?.frames(ofBrowser: tab.browserID)
        case is HibernatedBrowserTab, is DeferredBrowserTab: []
        default: nil
        }
    }

    nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }
}
