#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.new_terminal_trace` (DEBUG builds, cx-6so.58): where the time goes
/// between the New Terminal Tab action and the new shell's first visible
/// prompt, stage by stage (``NewTerminalTrace``).
///
/// `action`:
/// - `run`: arms a trace, performs `newSurface` as a person does (keyboard
///   origin, the focused pane of the active window; it selects and focuses
///   the new tab like the shortcut, nothing more), waits for
///   `prompt_contents` or `timeout_ms` (default 10000, at most 15000), then
///   closes that tab. Returns the trace and whether the tab was closed.
/// - `get` (default): the last `count` traces (default 10), oldest first.
///
/// A trace is `terminal_id`, `surface`, `timed_out` and `marks_ms`: each
/// mark's milliseconds after `action` (null: it never ran), and `order`, the
/// marks that ran by time. The command runs on the main actor (it performs
/// an action and closes a tab) and suspends while it waits.
@MainActor
enum DebugNewTerminalTrace {
    typealias JSON = CmuxNextSettings.JSONValue

    static let methodName = "debug.new_terminal_trace"

    static func method(_ services: AppServices) -> ControlMethod {
        ControlMethod.async(methodName) { [weak services] call in
            await DebugNewTerminalTrace.handle(call.params, services)
        }.withDeadline(.fixed(.seconds(20)))
    }

    static func handle(_ params: [String: JSON], _ services: AppServices?) async -> JSON {
        guard let services else { return .null }
        switch params["action"]?.stringValue ?? "get" {
        case "run":
            return await run(params, services)
        case "get":
            let count = min(max(params["count"]?.intValue ?? 10, 1), NewTerminalTrace.capacity)
            return .object(["traces": .array(NewTerminalTrace.shared.recent(count).map(json))])
        default:
            return .object(["error": .string("unknown action; use run or get")])
        }
    }

    private static func run(_ params: [String: JSON], _ services: AppServices) async -> JSON {
        let trace = NewTerminalTrace.shared
        guard trace.begin() else { return .object(["error": .string("a trace is already running")]) }
        let timeout = min(max(params["timeout_ms"]?.intValue ?? 10_000, 100), 15_000)
        guard services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)) else {
            _ = trace.finish(timedOut: false)
            return .object(["error": .string("newSurface did not run (no focused daemon pane?)")])
        }
        let prompted = await trace.waitForPrompt(timeout: .milliseconds(timeout))
        guard let record = trace.finish(timedOut: !prompted) else { return .null }
        guard case .object(var result) = json(record) else { return .null }
        result["closed"] = .bool(close(record, services))
        return .object(result)
    }

    /// Closes the traced tab the way a script does; false when it is not in the local daemon's store.
    private static func close(_ record: NewTerminalTrace.Record, _ services: AppServices) -> Bool {
        guard let surface = record.surface, let tab = services.locateTab(surface: SurfaceID(rawValue: surface)) else { return false }
        return services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id),
                                                                                 origin: .script))
    }

    private static func json(_ record: NewTerminalTrace.Record) -> JSON {
        var marks: [String: JSON] = [:]
        var ran: [(String, Double)] = []
        for mark in NewTerminalTrace.Mark.allCases {
            guard let ms = record.milliseconds(mark) else {
                marks[mark.name] = .null
                continue
            }
            let rounded = (ms * 1_000).rounded() / 1_000
            marks[mark.name] = .number(rounded)
            ran.append((mark.name, rounded))
        }
        return .object([
            "terminal_id": record.terminal.map(JSON.string) ?? .null,
            "surface": record.surface.map { JSON.number(Double($0)) } ?? .null,
            "timed_out": .bool(record.timedOut),
            "marks_ms": .object(marks),
            "order": .array(ran.sorted { $0.1 < $1.1 }.map { JSON.string($0.0) }),
        ])
    }
}
#endif
