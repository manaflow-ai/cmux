#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// `debug.chat_open_trace` (DEBUG builds): where the time goes between opening an agent chat and
/// its content on screen, stage by stage, and which surface the pane showed in each frame
/// (``ChatOpenTrace``). Leo 2026-10-22: "flickers the initial thing ... then it just goes to
/// black screen for a while".
///
/// `action`:
/// - `arm`: arms a trace and marks `action` now; the caller then opens a chat its own way (an
///   `action.run` of `palette.newAgentChat`, a sidebar click).
/// - `wait`: waits until the armed trace's chat shows (its loading cover left and no hold keeps it
///   hidden) or `timeout_ms` (default 10000, at most 15000), samples `settle_ms` more of frames
///   (default 300), finishes the trace and returns it.
///   `page_timing: true` adds the page's own clock (navigation, paint and resource timing).
/// - `finish`: finishes the running trace now (a launch trace) and returns it.
/// - `get` (default): the last `count` traces (default 10), oldest first, the running one last.
///
/// `CMUX_CHAT_OPEN_TRACE_LAUNCH=1` or `--chat-open-trace-launch` arms a trace at launch
/// (``ChatOpenTrace/shared``), timed from the process start, so the first pane a relaunch restores
/// is traced; `finish` ends it.
///
/// A trace is `id`, `launch`, `engine`, `timed_out`, `armed_wall`, `marks_ms` (each mark's
/// milliseconds after the action, or after arming with none; null: it never ran), `order`,
/// `frames` (the surface changes: `[ms, surface]`), `frame_count`, `first_content_ms` and
/// `longest_empty_ms` (the longest run of `cover` or `page_empty` frames).
@MainActor
enum DebugChatOpenTrace {
    typealias JSON = CmuxNextSettings.JSONValue

    static let methodName = "debug.chat_open_trace"

    static func method(_ services: AppServices) -> ControlMethod {
        ControlMethod.async(methodName) { [weak services] call in
            await DebugChatOpenTrace.handle(call.params, services)
        }.withDeadline(.fixed(.seconds(20)))
    }

    static func handle(_ params: [String: JSON], _ services: AppServices?) async -> JSON {
        let trace = ChatOpenTrace.shared
        switch params["action"]?.stringValue ?? "get" {
        case "arm":
            guard trace.begin() else { return .object(["error": .string("a trace is already running")]) }
            trace.mark(.action)
            return .object(["armed": .bool(true)])
        case "wait":
            guard let services else { return .null }
            return await wait(params, services)
        case "finish":
            return trace.finish(timedOut: false).map(json) ?? .null
        case "get":
            let count = min(max(params["count"]?.intValue ?? 10, 1), ChatOpenTrace.capacity)
            return .object(["traces": .array(trace.recent(count).map(json))])
        default:
            return .object(["error": .string("unknown action; use arm, wait, finish or get")])
        }
    }

    private static func wait(_ params: [String: JSON], _ services: AppServices) async -> JSON {
        let trace = ChatOpenTrace.shared
        guard trace.isArmed else { return .object(["error": .string("no trace is armed")]) }
        let timeout = min(max(params["timeout_ms"]?.intValue ?? 10_000, 100), 15_000)
        let settle = min(max(params["settle_ms"]?.intValue ?? 300, 0), 2_000)
        let shown = await trace.waitUntilShown(timeout: .milliseconds(timeout))
        await trace.settle(for: .milliseconds(settle))
        guard case .object(var result)? = trace.finish(timedOut: !shown).map(json) else { return .null }
        if params["page_timing"]?.boolValue == true { result["page_timing"] = await pageTiming(params, services) }
        return .object(result)
    }

    /// The traced chat's own clock (`page_timing: true`), in either engine: its navigation timing,
    /// paint entries, the resources it loaded and when, and the time it marked painted.
    private static func pageTiming(_ params: [String: JSON], _ services: AppServices) async -> JSON {
        guard case .success(let (_, view)) = DebugAgentPane.agentPane(params, services: services) else { return .null }
        let script = """
            const nav = performance.getEntriesByType("navigation")[0];
            const round = (value) => Math.round(value * 10) / 10;
            return JSON.stringify({
              navigation: nav ? { response_start: round(nav.responseStart), response_end: round(nav.responseEnd),
                dom_interactive: round(nav.domInteractive), dom_content_loaded: round(nav.domContentLoadedEventEnd),
                load: round(nav.loadEventEnd) } : null,
              paint: performance.getEntriesByType("paint").map((entry) => [entry.name, round(entry.startTime)]),
              resources: performance.getEntriesByType("resource").map((entry) => [entry.name.split("/").pop(),
                round(entry.startTime), round(entry.responseEnd), entry.transferSize]),
              painted: Number(document.documentElement.dataset.cmuxPainted ?? NaN),
            });
            """
        guard let text = try? await view.callPageScript(script) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let value = JSON(foundation: object) else { return .null }
        return value
    }

    private static func json(_ record: ChatOpenTrace.Record) -> JSON {
        func rounded(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }
        var marks: [String: JSON] = [:]
        var ran: [(String, Double)] = []
        for mark in ChatOpenTrace.Mark.allCases {
            guard let ms = record.milliseconds(mark) else {
                marks[mark.name] = .null
                continue
            }
            marks[mark.name] = .number(rounded(ms))
            ran.append((mark.name, rounded(ms)))
        }
        return .object([
            "id": .number(Double(record.id)),
            "launch": .bool(record.launch),
            "engine": record.engine.map(JSON.string) ?? .null,
            "timed_out": .bool(record.timedOut),
            "armed_wall": .number(record.armedWall),
            "marks_ms": .object(marks),
            "order": .array(ran.sorted { $0.1 < $1.1 }.map { JSON.string($0.0) }),
            "frames": .array(record.surfaces.map { .array([.number(rounded($0.ms)), .string($0.surface.rawValue)]) }),
            "frame_count": .number(Double(record.frameCount)),
            "first_content_ms": record.firstContentMilliseconds.map { JSON.number(rounded($0)) } ?? .null,
            "longest_empty_ms": .number(rounded(record.longestEmptyMilliseconds)),
            "note": record.note.map(JSON.string) ?? .null,
        ])
    }
}
#endif
