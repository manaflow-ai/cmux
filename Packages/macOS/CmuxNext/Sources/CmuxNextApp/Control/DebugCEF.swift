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

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
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
