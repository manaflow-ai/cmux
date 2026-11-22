public import CmuxNextActions
public import CmuxNextDaemon
public import CmuxNextDaemonService

/// Which rows the bulk closes take, and whether a batch close likely asks first: pure reads of a
/// sidebar's order and the store, shared by the palette, the row menus and the selection close.
extension WorkspaceClose {
    /// What Close Other Workspaces, Close Workspaces Below and Close Workspaces Above (`id`)
    /// close of `order` (a sidebar's rows) around the rows `kept`: every other row, the rows
    /// below the last kept one, or the rows above the first.
    ///
    /// - Parameters:
    ///   - kept: The rows the close keeps (the target, or the selection it belongs to).
    ///   - id: `palette.closeOtherWorkspaces`, `palette.closeWorkspacesBelow` or `palette.closeWorkspacesAbove`.
    ///   - order: The sidebar's list rows, top to bottom.
    /// - Returns: The rows to close, in order; empty when `order` holds none of `kept`.
    public static func keeping(_ kept: Set<String>, id: ActionID, order: [String]) -> [String] {
        guard let first = order.firstIndex(where: kept.contains), let last = order.lastIndex(where: kept.contains) else { return [] }
        switch id {
        case "palette.closeOtherWorkspaces": return order.filter { !kept.contains($0) }
        case "palette.closeWorkspacesBelow": return Array(order[(last + 1)...])
        default: return Array(order[..<first])
        }
    }

    /// What the same closes take of `order` (a sidebar's list rows) from a pinned workspace, which draws
    /// in Pinned above the list: every row for Others and Below, none for Above. Before, Cmd-Shift-P's run on
    /// a pinned workspace was refused with "the workspace is not in the sidebar" (Lawrence 2026-11-05).
    ///
    /// - Parameters:
    ///   - id: The close's action id, as for ``keeping(_:id:order:)``.
    ///   - order: The sidebar's list rows, top to bottom.
    /// - Returns: The rows to close, in order.
    public static func aroundPinned(id: ActionID, order: [String]) -> [String] {
        id == "palette.closeWorkspacesAbove" ? [] : order
    }

    /// Whether a batch close's question will likely show, read from the store without the daemon: two
    /// or more close with nothing to undo it (`askWithoutUndo`), or (`warn`) one has a live terminal on a
    /// connected machine that is not known to sit at its shell prompt (OSC 133, `TabModel.promptSinceMs`).
    /// True: the rows stay until the answer. False: they leave at the press, and the terminals are
    /// still asked behind them (a prompt can show while ssh or a nested shell runs, `WorkspaceCloseFlow`).
    ///
    /// - Parameters:
    ///   - members: The workspaces that close, each with its daemon.
    ///   - warn: `app.warnBeforeClosingTab`.
    ///   - askWithoutUndo: No window stays open to show the undo toast.
    /// - Returns: Whether the rows should stay until the question is answered.
    @MainActor
    public static func mayAsk(_ members: [(WorkspaceModel, DaemonService)], warn: Bool, askWithoutUndo: Bool = false) -> Bool {
        if askWithoutUndo, members.count > 1 { return true }
        return warn && members.contains { workspace, daemon in
            daemon.isLive && workspace.screens.flatMap(\.panes).flatMap(\.tabs).contains(where: mayRunProgram)
        }
    }

    /// Whether `tab` is a live terminal whose shell may be running a program: a command runs, or no
    /// prompt was seen.
    ///
    /// - Parameter tab: The tab to read.
    /// - Returns: True for a live PTY tab with a command running or no prompt seen yet.
    @MainActor
    public static func mayRunProgram(_ tab: TabModel) -> Bool {
        tab.kind == .pty && !tab.dead && (tab.commandSinceMs != nil || tab.promptSinceMs == nil)
    }
}
