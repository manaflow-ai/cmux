#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDaemon
import CmuxNextSettings

private typealias JSON = CmuxNextSettings.JSONValue

/// `debug.new_tab {action: "bench_create", command}` (DEBUG builds): the instant-create budget of
/// Cmd-N, Cmd-T, Ctrl-` (New Terminal Tab), Cmd-D and Cmd-Shift-D, each driven through the real
/// key path (`debug.key`).
///
/// Per run it reports, in ms after the key:
/// - `key_ms`: the key's synchronous main-thread time (handler included);
/// - `visible_ms`: the first display frame at which the result shows (Cmd-N: the window shows
///   another workspace; Cmd-T, Ctrl-`: the focused pane shows another tab; Cmd-D / Cmd-Shift-D: the
///   window's focused pane is a new pane);
/// - `confirmed_ms`: the first frame at which the daemon's object replaced the provisional one
///   (no `pending_tab_` id, no provisional pane handle), or null within 5 s;
/// - `frames_to_visible`: display frames from the key to `visible_ms` (1 = the next frame);
/// - `spans`: the main-thread spans and marks `BenchSpans` recorded (handler stages, daemon reply).
@MainActor
enum DebugInstantCreateBench {
    private static let frames = BenchFrames()

    enum Command: String, CaseIterable {
        case newWorkspace = "new_workspace", newTab = "new_tab", newTerminal = "new_terminal", splitRight = "split_right", splitDown = "split_down"

        var key: (String, [String]) {
            switch self {
            case .newWorkspace: ("n", ["command"])
            case .newTab: ("t", ["command"])
            case .newTerminal: ("`", ["control"])
            case .splitRight: ("d", ["command"])
            case .splitDown: ("d", ["command", "shift"])
            }
        }
    }

    static func run(_ params: [String: CmuxNextSettings.JSONValue], _ controller: WindowController, _ services: AppServices) async -> CmuxNextSettings.JSONValue {
        guard let command = params["command"]?.stringValue.flatMap(Command.init(rawValue:)) else {
            return .object(["error": .string("command: one of \(Command.allCases.map(\.rawValue).joined(separator: ", "))")])
        }
        let before = Probe(controller)
        let (key, modifiers) = command.key
        frames.start()
        BenchSpans.begin()
        let start = ContinuousClock.now
        _ = DebugKey.send(["key": .string(key), "modifiers": .array(modifiers.map(JSON.string)),
                           "window": .string(controller.state.id)], services: services)
        let keyMilliseconds = BenchSpans.ms(.now - start)
        let visible = await frames.settled(until: { before.changed(command, Probe(controller)) }, start: start, window: 0, deadline: 5_000)
        let confirmed = visible == nil ? nil
            : await frames.settled(until: { Probe(controller).confirmed(command) }, start: start, window: 0, deadline: 5_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        var refresh = 1_000.0 / 60
        if case .object(let fields) = stats, let value = fields["refresh_ms"]?.doubleValue, value > 0 { refresh = value }
        return .object([
            "command": .string(command.rawValue),
            "key_ms": .number(keyMilliseconds),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "confirmed_ms": confirmed.map { .number($0) } ?? .null,
            "frames_to_visible": visible.map { .number(($0 / refresh).rounded(.up)) } ?? .null,
            "main_thread_spans_ms": .number(spans.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
        ])
    }

    /// What the window shows, read each frame.
    private struct Probe {
        var workspace: String?
        var pane: ObjectIdentifier?
        var paneHandle: UInt64?
        var paneCount: Int
        var tab: String?

        init(_ controller: WindowController) {
            let content = controller.content
            workspace = content?.workspace.id
            let focused = content?.focusedPane
            pane = focused.map(ObjectIdentifier.init)
            paneHandle = focused?.pane.handle.rawValue
            paneCount = content?.panes.count ?? 0
            tab = focused?.currentTabKey
        }

        func changed(_ command: Command, _ now: Probe) -> Bool {
            switch command {
            case .newWorkspace: now.workspace != nil && now.workspace != workspace
            case .newTab, .newTerminal: now.pane == pane && now.tab != nil && now.tab != tab
            case .splitRight, .splitDown: now.workspace == workspace && now.pane != pane && now.paneCount > paneCount
            }
        }

        func confirmed(_ command: Command) -> Bool {
            let realTab = tab.map { !$0.hasPrefix(ProvisionalTab.idPrefix) } ?? false
            switch command {
            case .newWorkspace, .newTab, .newTerminal: return realTab
            case .splitRight, .splitDown: return realTab && (paneHandle ?? .max) < (1 << 62)
            }
        }
    }
}
#endif
