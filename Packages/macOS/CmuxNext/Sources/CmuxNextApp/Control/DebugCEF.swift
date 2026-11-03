import AppKit
import CmuxNextBrowser
import CmuxNextChromiumRuntime
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Darwin

/// `debug.cef`: how Chromium started in this process (lazy tab, or a warm
/// start and why), its timings, the app's memory footprint, the default
/// engine, why Chromium is unavailable (`unavailable`: `notBundled`,
/// `downloading`, `downloadFailed`, `startFailed`, `shutDown`), where the
/// runtime came from (`runtime`: Chromium on demand) and the WebKit
/// fallbacks so far, the external pump's counters (`pump`) and what the
/// fork's page tracker read from host views (`tracker`). Helper
/// processes are separate; measure them with `ps`.
@MainActor
enum DebugCEF {
    /// The engine's state, read on the main actor, then its footprint (`task_info`, a system call) on a
    /// ``BackgroundWork`` system lane: a diagnostic never makes one on the main thread.
    static func report(_ services: AppServices) -> ControlReply {
        let report = services.cache.cef.startReport
        var object: [String: JSONValue] = [
            "state": .string(report.state),
            "preloaded": .bool(report.preloaded),
            "likely": services.chromiumWarmup.reason.map { .string($0.rawValue) } ?? .null,
            "trigger": report.trigger.map { .string($0) } ?? .null,
            "spare_window": .string(services.cache.cef.spareWindowState),
            "engine_start_main_ms": .number(milliseconds(services.cache.cef.engineStartMainThreadTime)),
            "start_steps": .array(services.cache.cef.startMarks.map {
                .object(["name": .string($0.name), "start_uptime_ns": .number(Double($0.startUptimeNanos)), "ms": .number($0.milliseconds)])
            }),
            "prefetch": services.cache.cef.frameworkPrefetchFields.map { .object($0.mapValues { .number($0) }) } ?? .null,
        ]
        if case let browserTabs = services.cache.browserTabs {
            object["default_engine"] = .string(browserTabs.preference.defaultEngine.rawValue)
            // The engine's reason, not `browserTabs.cefUnavailable()`: that read asks for the download.
            object["unavailable"] = unavailable(services.cache.cef.unavailableReason)
            let fallbacks = browserTabs.fallbacks
            object["fallback"] = fallbacks.count == 0 ? .null : .object([
                "count": .number(Double(fallbacks.count)),
                "reason": unavailable(fallbacks.lastReason),
                "source": fallbacks.lastSource.map { .string($0.rawValue) } ?? .null,
                "notified": .bool(fallbacks.notified),
            ])
        }
        object["runtime"] = runtime(services.chromiumRuntime)
        object["devtools"] = .array(devTools(services))
        if let pump = services.cache.cef.pumpStats { object["pump"] = pumpReport(pump) }
        object["tracker"] = trackerReport(services.cache.cef.trackerStats)
        object["windows"] = windows(services.cache.cef.windowReport)
        if let duration = report.loadDuration { object["load_ms"] = .number(milliseconds(duration)) }
        if let duration = report.initializeDuration { object["initialize_ms"] = .number(milliseconds(duration)) }
        if let seconds = report.readyAfterLaunch { object["ready_after_launch_s"] = .number(seconds) }
        let fields = object
        return .followUp { [work = services.work] in
            var fields = fields
            // Unread (cancelled, shutting down) is null, never a footprint of 0.
            fields["footprint_mb"] = (try? await work.run(.bestEffort, mayBlock: .system) { footprintMegabytes() }).map(JSONValue.number) ?? .null
            return .object(fields)
        }
    }

    /// Per shown Chromium tab: its DevTools state, the page and docked
    /// DevTools areas and the Chromium child windows over the tab (screen
    /// coordinates, AppKit origin), so a check can see that the DevTools
    /// window sits exactly over its area.
    private static func devTools(_ services: AppServices) -> [JSONValue] {
        var out: [JSONValue] = []
        for controller in services.windows.controllers {
            guard let window = controller.window else { continue }
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard case .browser(let entry)? = pane.currentContent, let tab = entry.tab as? CEFTab else { continue }
                let state = tab.devTools
                var object: [String: JSONValue] = [
                    "tab": .string(tab.id.rawValue), "pane": .string(pane.paneKey),
                    "url": tab.state.url.map { .string($0.absoluteString) } ?? .null,
                    "title": tab.state.title.map { .string($0) } ?? .null,
                    "open": .bool(state.isOpen), "dock": .string(state.dock.rawValue),
                ]
                if let panel = tab.sidePanelDiagnostic {
                    object["side_panel"] = .object(["title": .string(panel.title), "pinned": .bool(panel.pinned),
                                                    "controls": .array(panel.controls.map { .string($0) }), "frame": rect(panel.frame),
                                                    "chromium_focusable": panel.chromiumFocusable.map { .number(Double($0)) } ?? .null])
                }
                if let frames = tab.devToolsDiagnosticFrames {
                    object["page_frame"] = rect(frames.page)
                    object["devtools_frame"] = frames.devTools.map(rect) ?? .null
                    let content = frames.devTools.map { frames.page.union($0) } ?? frames.page
                    let children = WindowOverlayLayer.contentChildWindows(of: window).filter { $0.frame.intersects(content) }
                    object["child_windows"] = .array(children.map { child in
                        .object(["frame": rect(child.frame), "devtools": .bool(tab.devToolsContains(window: child)),
                                 "key": .bool(child.isKeyWindow), "visible": .bool(child.isVisible)])
                    })
                }
                out.append(.object(object))
            }
        }
        return out
    }

    /// Runs `control` on the first shown Chromium tab with a side panel.
    static func pressSidePanel(_ control: String, services: AppServices) {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard case .browser(let entry)? = pane.currentContent, let tab = entry.tab as? CEFTab else { continue }
                if tab.pressSidePanelForDebug(control) { return }
            }
        }
    }

    /// Chromium never opens a window of its own: `chromium_windows` must be
    /// empty; `guard_blocked` counts windows the app hid after they showed.
    private static func windows(_ report: CEFWindowReport) -> JSONValue {
        .object([
            "chromium_windows": .array(report.chromiumWindows.map { .string($0) }),
            "requests": .number(Double(report.requests)),
            "refused": .number(Double(report.refused)),
            "recent": .array(report.recent.map { .string($0) }),
            "blocked_commands": .array(report.blockedCommands.map { .number(Double($0)) }),
            "fork_foreign_browsers": .number(Double(report.foreignBrowsers)),
            "guard_blocked": .number(Double(report.guardBlocked)),
            "guard_recent": .array(report.guardRecent.map { .string($0) }),
            "unplaced_tabs": .number(Double(report.unplacedTabs)),
            "fork_api": .number(Double(report.forkAPIVersion)),
            "popup_windows": .array(report.popupWindows.map { .string($0) }),
        ])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }

    /// Pump wakeups per second = the change of `work_runs` over an interval.
    private static func pumpReport(_ stats: CEFPumpStats) -> JSONValue {
        .object([
            "work_runs": .number(Double(stats.workRuns)),
            "immediate_requests": .number(Double(stats.immediateRequests)),
            "delayed_requests": .number(Double(stats.delayedRequests)),
            "reentrant_fires": .number(Double(stats.reentrantFires)),
            "long_work_runs": .number(Double(stats.longWorkRuns)),
            "follow_up_runs": .number(Double(stats.followUpRuns)),
            "kept_cross_thread_requests": .number(Double(stats.keptCrossThreadRequests)),
            "work_ms": .number(stats.workSeconds * 1_000),
            "fallback_ms": .number(stats.fallbackInterval * 1_000),
        ])
    }

    /// Per action = the change of each counter over it (scripts/cmux-next/pane-perf-terminal.py --browser).
    private static func trackerReport(_ stats: CEFTrackerStats) -> JSONValue {
        .object([
            "clip_reads": .number(Double(stats.clipReads)),
            "occlusion_reads": .number(Double(stats.occlusionReads)),
            "clip_builds": .number(Double(stats.clipBuilds)),
            "clip_hits": .number(Double(stats.clipHits)),
            "clip_ms": .number(stats.clipSeconds * 1_000),
            "geometry_posts": .number(Double(stats.geometryPosts)),
            "hosted_pages": .number(Double(stats.hostedPages)),
            "hosting_refused": .number(Double(stats.hostingRefused)),
            "geometry_skips": .number(Double(stats.geometrySkips)),
        ])
    }

    /// Where the runtime came from and the download state (Chromium on demand).
    private static func runtime(_ service: ChromiumRuntimeService) -> JSONValue {
        var object: [String: JSONValue] = [
            "origin": .string(service.origin.rawValue),
            "pinned_key": service.pinnedKey.map { .string($0) } ?? .null,
            "install": .string(service.state.name),
            "fraction": service.state.fraction.map { .number($0) } ?? .null,
            "frameworks": service.source.layout.map { .string($0.frameworksDirectory.path) } ?? .null,
        ]
        if case .failed(let error, let attempt) = service.state {
            object["error"] = .object(["code": .string(error.code), "detail": .string(error.detail), "attempt": .number(Double(attempt))])
        }
        return .object(object)
    }

    private static func unavailable(_ reason: CEFUnavailableReason?) -> JSONValue {
        guard let reason else { return .null }
        return .object(["code": .string(reason.code), "detail": reason.detail.map { .string($0) } ?? .null])
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// `phys_footprint` (Activity Monitor's "Memory"), in MiB.
    nonisolated static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
