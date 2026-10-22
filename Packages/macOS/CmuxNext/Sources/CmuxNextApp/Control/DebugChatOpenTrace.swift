#if DEBUG
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
/// - `run`: arms a trace, performs `palette.newAgentChat` as a person does, waits until the chat
///   shows (its loading cover left and no hold keeps it hidden) or `timeout_ms` (default 10000, at
///   most 15000), samples `settle_ms` more of frames (default 300), and returns the trace.
/// - `arm`: arms a trace with no action, for an open driven another way; `finish` ends it.
/// - `get` (default): the last `count` traces (default 10), oldest first, the running one last.
///
/// `CMUX_CHAT_OPEN_TRACE_LAUNCH=1` arms a trace when the control methods are made at launch, so
/// the first pane a relaunch restores is traced; `finish` ends it.
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
        if ProcessInfo.processInfo.environment["CMUX_CHAT_OPEN_TRACE_LAUNCH"] == "1" {
            _ = ChatOpenTrace.shared.begin(launch: true)
        }
        return ControlMethod.async(methodName) { [weak services] call in
            await DebugChatOpenTrace.handle(call.params, services)
        }.withDeadline(.fixed(.seconds(20)))
    }

    static func handle(_ params: [String: JSON], _ services: AppServices?) async -> JSON {
        guard let services else { return .null }
        let trace = ChatOpenTrace.shared
        switch params["action"]?.stringValue ?? "get" {
        case "run":
            return await run(params, services)
        case "arm":
            return .object(["armed": .bool(trace.begin())])
        case "finish":
            return trace.finish(timedOut: false).map(json) ?? .null
        case "get":
            let count = min(max(params["count"]?.intValue ?? 10, 1), ChatOpenTrace.capacity)
            return .object(["traces": .array(trace.recent(count).map(json))])
        default:
            return .object(["error": .string("unknown action; use run, arm, finish or get")])
        }
    }

    private static func run(_ params: [String: JSON], _ services: AppServices) async -> JSON {
        let trace = ChatOpenTrace.shared
        guard trace.begin() else { return .object(["error": .string("a trace is already running")]) }
        let timeout = min(max(params["timeout_ms"]?.intValue ?? 10_000, 100), 15_000)
        let settle = min(max(params["settle_ms"]?.intValue ?? 300, 0), 2_000)
        trace.mark(.action)
        guard services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)) else {
            _ = trace.finish(timedOut: false)
            return .object(["error": .string("palette.newAgentChat did not run")])
        }
        let shown = await trace.waitUntilShown(timeout: .milliseconds(timeout))
        await trace.settle(for: .milliseconds(settle))
        return trace.finish(timedOut: !shown).map(json) ?? .null
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
        ])
    }
}
#endif
