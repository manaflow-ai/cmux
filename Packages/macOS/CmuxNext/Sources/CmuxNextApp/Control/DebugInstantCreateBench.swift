#if DEBUG
import AppKit
import CmuxNextDaemon
import CmuxNextSettings

private typealias JSON = CmuxNextSettings.JSONValue

/// `debug.new_tab {action: "bench_create", command}` (DEBUG builds): the instant-create budget of
/// Cmd-N, Cmd-T, Ctrl-` (New Terminal Tab), Cmd-D, Cmd-Shift-D, Ctrl-Cmd-D (New Column) and Cmd-I
/// (New Agent Chat), each driven through the real key path (`debug.key`).
///
/// Per run it reports, in ms after the key:
/// - `key_ms`: the key's synchronous main-thread time (handler included);
/// - `visible_ms`: the first display frame at which the result shows (Cmd-N: the window shows
///   another workspace; Cmd-T, Ctrl-`: the focused pane shows another tab; Cmd-D / Cmd-Shift-D /
///   New Column: the window's focused pane is a new pane; New Agent Chat: a tab the window did not
///   show before shows in one of its panes, wherever the chat placement puts it, a new workspace
///   included, and a chat held hidden for its new dock only once the dock shows it);
/// - `confirmed_ms`: the first frame at which the daemon's object replaced the provisional one
///   (no `pending_tab_` id, no provisional pane handle), or null within 5 s;
/// - `frames_to_visible`: display frames from the key to `visible_ms` (1 = the next frame);
/// - `spans`: the main-thread spans and marks `BenchSpans` recorded (handler stages, daemon reply);
/// - New Agent Chat only: `added_tabs` (the tabs the chat added, for the caller to close by id, not
///   the focused tab) and `workspace_changed` (the placement opened it in another workspace).
@MainActor
enum DebugInstantCreateBench {
    private static let frames = BenchFrames()

    enum Command: String, CaseIterable {
        case newWorkspace = "new_workspace", newTab = "new_tab", newTerminal = "new_terminal", splitRight = "split_right", splitDown = "split_down"
        case newColumn = "new_column", newChat = "new_chat"

        var key: (String, [String]) {
            switch self {
            case .newWorkspace: ("n", ["command"])
            case .newTab: ("t", ["command"])
            case .newTerminal: ("`", ["control"])
            case .splitRight: ("d", ["command"])
            case .splitDown: ("d", ["command", "shift"])
            case .newColumn: ("d", ["control", "command"])
            case .newChat: ("i", ["command"])
            }
        }
    }

    static func run(_ params: [String: CmuxNextSettings.JSONValue], _ controller: WindowController, _ services: AppServices) async -> CmuxNextSettings.JSONValue {
        guard let command = params["command"]?.stringValue.flatMap(Command.init(rawValue:)) else {
            return .object(["error": .string("command: one of \(Command.allCases.map(\.rawValue).joined(separator: ", "))")])
        }
        let before = Probe(controller, command)
        let (key, modifiers) = command.key
        frames.start()
        BenchSpans.begin()
        let start = ContinuousClock.now
        _ = DebugKey.send(["key": .string(key), "modifiers": .array(modifiers.map(JSON.string)),
                           "window": .string(controller.state.id)], services: services)
        let keyMilliseconds = BenchSpans.ms(.now - start)
        let visible = await frames.settled(until: { before.changed(command, Probe(controller, command)) }, start: start, window: 0, deadline: 5_000)
        let confirmed = visible == nil ? nil
            : await frames.settled(until: { Probe(controller, command).confirmed(command, since: before) }, start: start, window: 0, deadline: 5_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        var refresh = 1_000.0 / 60
        if case .object(let fields) = stats, let value = fields["refresh_ms"]?.doubleValue, value > 0 { refresh = value }
        var chat: [String: JSON] = [:]
        if command == .newChat {
            let after = Probe(controller, command)
            chat["added_tabs"] = .array(after.tabs.subtracting(before.tabs).sorted().map(JSON.string))
            chat["workspace_changed"] = .bool(after.workspace != before.workspace)
        }
        let visibleValue: JSON = visible.map { JSON.number($0) } ?? .null
        let confirmedValue: JSON = confirmed.map { JSON.number($0) } ?? .null
        let framesValue: JSON = visible.map { JSON.number(($0 / refresh).rounded(.up)) } ?? .null
        let spansTotal: Double = spans.reduce(0.0) { $0 + $1.milliseconds }
        let spanValues: [JSON] = spans.map { span -> JSON in
            .object(["name": .string(span.name), "at": .number(span.start), "ms": .number(span.milliseconds)])
        }
        let fields: [String: JSON] = [
            "command": .string(command.rawValue),
            "key_ms": .number(keyMilliseconds),
            "visible_ms": visibleValue,
            "confirmed_ms": confirmedValue,
            "frames_to_visible": framesValue,
            "main_thread_spans_ms": .number(spansTotal),
            "spans": .array(spanValues),
            "frames": stats,
        ]
        return .object(chat.merging(fields) { $1 })
    }

    /// What the window shows, read each frame.
    private struct Probe {
        var workspace: String?
        var pane: ObjectIdentifier?
        var paneHandle: UInt64?
        var paneCount: Int
        var tab: String?
        /// Every tab id the window's panes show (a new chat may open in another pane or a dock);
        /// read for New Agent Chat only, so the other commands' frame polls build no set of every
        /// tab inside the frames they measure (STRESS: 72 tabs in the measured workspace). A chat
        /// bound for a new dock is held hidden in the pane it opened from until the dock takes it
        /// (`dockBound`): it is not visible there, so it counts once its dock shows it.
        var tabs: Set<String> = []

        init(_ controller: WindowController, _ command: Command) {
            let content = controller.content
            workspace = content?.workspace.id
            let focused = content?.focusedPane
            pane = focused.map(ObjectIdentifier.init)
            paneHandle = focused?.pane.handle.rawValue
            paneCount = content?.panes.count ?? 0
            tab = focused?.currentTabKey
            if command == .newChat, let content {
                for controller in content.panes.values {
                    let hidden = controller.dockBound
                    tabs.formUnion(controller.pane.tabs.map(\.id).filter { !hidden.contains($0) })
                }
            }
        }

        func changed(_ command: Command, _ now: Probe) -> Bool {
            switch command {
            case .newWorkspace: now.workspace != nil && now.workspace != workspace
            case .newTab, .newTerminal: now.pane == pane && now.tab != nil && now.tab != tab
            case .splitRight, .splitDown, .newColumn: now.workspace == workspace && now.pane != pane && now.paneCount > paneCount
            // Wherever the chat placement puts it: this workspace's panes or a new workspace.
            case .newChat: !now.tabs.subtracting(tabs).isEmpty
            }
        }

        func confirmed(_ command: Command, since before: Probe) -> Bool {
            let realTab = tab.map { !$0.hasPrefix(ProvisionalTab.idPrefix) } ?? false
            switch command {
            case .newWorkspace, .newTab, .newTerminal: return realTab
            case .splitRight, .splitDown, .newColumn: return realTab && (paneHandle ?? .max) < (1 << 62)
            case .newChat:
                let added = tabs.subtracting(before.tabs)
                return !added.isEmpty && !added.contains { $0.hasPrefix(ProvisionalTab.idPrefix) }
            }
        }
    }
}
#endif
