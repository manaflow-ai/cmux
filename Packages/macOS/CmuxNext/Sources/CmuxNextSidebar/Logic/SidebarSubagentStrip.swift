public import CmuxNextDesign
import Foundation

/// How a chat row shows its subagents (Debug `sidebar.subagents.look`): the three looks the gallery
/// compares. `both`, the default, is the Claude desktop app's: rows under an open parent, one
/// stacked line under a folded one.
public nonisolated enum SidebarSubagentLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One row per subagent, indented under the chat on a thin tree line.
    case rows
    /// One line under the chat: the subagents' marks stacked and a count ("3 running").
    case stack
    /// Rows while the chat is open in the session tree, the stacked line while it is folded.
    case both

    public var tunableTitle: String {
        switch self {
        case .rows: "Rows on a tree line"
        case .stack: "One stacked line"
        case .both: "Rows when open, stacked line when folded"
        }
    }
}

/// What a workspace row draws of its chats' subagents under its name (`WorkspaceRowContent.subagents`):
/// rows (each clickable, at most `visibleRows`, then "N more") or one stacked line. Its lines add to
/// the row's height (`SidebarLayoutMetrics.subagentsHeight`), so the rows below move with it.
public nonisolated struct SidebarSubagentStrip: Hashable, Sendable {
    public enum Mode: Hashable, Sendable { case rows, stack }

    public var mode: Mode
    /// Rows mode: the rows drawn, oldest first, each with its depth under the chat (1, or 2 under
    /// another listed subagent).
    public var rows: [Row]
    /// Rows mode: the subagents past `rows` ("N more", which opens the chat).
    public var more: Int
    /// Stack mode: the marks drawn, at most `stackMarks`, running ones first.
    public var marks: [SidebarSubagent.State]
    /// Stack mode: how many run, finished and failed.
    public var running: Int, done: Int, failed: Int
    /// The chat tab "N more" and the stacked line open (the first listed subagent's).
    public var tab: TabID?

    public struct Row: Hashable, Sendable {
        public var subagent: SidebarSubagent
        public var depth: Int
    }

    /// The most rows a chat lists: a chat with many subagents costs the same rows (constant cost).
    public static let visibleRows = 5
    /// The most marks the stacked line draws.
    public static let stackMarks = 4

    /// Lines the strip takes under the row's name.
    public var lineCount: Int { mode == .stack ? 1 : rows.count + (more > 0 ? 1 : 0) }

    /// The strip for `subagents` under a row. `tree`: the session tree is on (`sidebar.sessionTree`);
    /// `folded`: the person folded this row there. With the tree off only running subagents show, as one
    /// stacked line that folds away when none runs.
    public static func make(_ subagents: SidebarSubagents?, tree: Bool, folded: Bool,
                            look: SidebarSubagentLook = .both) -> SidebarSubagentStrip? {
        guard let subagents, !subagents.isEmpty else { return nil }
        let items = subagents.items
        let failed = items.filter { $0.state == .failed }.count
        let rowsMode: Bool = switch look {
        case .rows: tree ? !folded : false
        case .stack: false
        case .both: tree && !folded
        }
        if rowsMode, !items.isEmpty {
            let shown = Array(items.suffix(visibleRows))
            let ids = Set(shown.map(\.id))
            let rows = shown.map { Row(subagent: $0, depth: $0.parent.map(ids.contains) == true ? 2 : 1) }
            return SidebarSubagentStrip(mode: .rows, rows: rows, more: max(0, subagents.total - shown.count), marks: [],
                                        running: subagents.running, done: 0, failed: failed, tab: shown.first?.tab ?? subagents.chat)
        }
        // Off the tree (or folded with nothing running under the rows look) only work that runs shows.
        if !tree && subagents.running == 0 { return nil }
        if look == .rows && subagents.running == 0 { return nil }
        let order: [SidebarSubagent.State] = [.running, .failed, .done, .stopped]
        let marks = items.sorted { (order.firstIndex(of: $0.state) ?? 0) < (order.firstIndex(of: $1.state) ?? 0) }
            .prefix(stackMarks).map(\.state)
        let done = max(0, subagents.total - subagents.running - failed)
        return SidebarSubagentStrip(mode: .stack, rows: [], more: 0,
                                    marks: marks.isEmpty ? [.running] : Array(marks),
                                    running: subagents.running, done: done, failed: failed,
                                    tab: items.first?.tab ?? subagents.chat)
    }
}
