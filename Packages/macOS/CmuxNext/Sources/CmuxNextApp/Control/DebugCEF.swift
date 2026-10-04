import AppKit
import CmuxNextBrowser
import CmuxNextSettings
import Darwin

/// `debug.cef`: how Chromium started in this process (lazy tab, or a warm
/// start and why), its timings, the app's memory footprint, the default
/// engine, why Chromium is unavailable (`unavailable`: `notBundled`,
/// `startFailed`, `shutDown`) and the WebKit fallbacks so far. Helper
/// processes are separate; measure them with `ps`.
@MainActor
enum DebugCEF {
    static func report(_ services: AppServices) -> JSONValue {
        let report = services.cache.cef.startReport
        var object: [String: JSONValue] = [
            "state": .string(report.state),
            "preloaded": .bool(report.preloaded),
            "likely": services.chromiumWarmup.reason.map { .string($0.rawValue) } ?? .null,
            "trigger": report.trigger.map { .string($0) } ?? .null,
            "footprint_mb": .number(footprintMegabytes()),
        ]
        if let browserTabs = services.cache.browserTabs {
            object["default_engine"] = .string(browserTabs.preference.defaultEngine.rawValue)
            object["unavailable"] = unavailable(browserTabs.cefUnavailable())
            let fallbacks = browserTabs.fallbacks
            object["fallback"] = fallbacks.count == 0 ? .null : .object([
                "count": .number(Double(fallbacks.count)),
                "reason": unavailable(fallbacks.lastReason),
                "source": fallbacks.lastSource.map { .string($0.rawValue) } ?? .null,
                "notified": .bool(fallbacks.notified),
            ])
        }
        object["devtools"] = .array(devTools(services))
        if let pump = services.cache.cef.pumpStats { object["pump"] = pumpReport(pump) }
        object["windows"] = windows(services.cache.cef.windowReport)
        if let duration = report.loadDuration { object["load_ms"] = .number(milliseconds(duration)) }
        if let duration = report.initializeDuration { object["initialize_ms"] = .number(milliseconds(duration)) }
        if let seconds = report.readyAfterLaunch { object["ready_after_launch_s"] = .number(seconds) }
        return .object(object)
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
            "work_ms": .number(stats.workSeconds * 1_000),
            "fallback_ms": .number(stats.fallbackInterval * 1_000),
        ])
    }

    private static func unavailable(_ reason: CEFUnavailableReason?) -> JSONValue {
        guard let reason else { return .null }
        return .object(["code": .string(reason.code), "detail": reason.detail.map { .string($0) } ?? .null])
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// `phys_footprint` (Activity Monitor's "Memory"), in MiB.
    static func footprintMegabytes() -> Double {
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
