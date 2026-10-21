import CmuxNextActions

/// One Close Workspace, in press order (Lawrence 2026-10-17: "this needs to be instant"). The
/// workspace is the one the press named, fixed then; its row leaves the sidebar and the selection
/// moves in that turn (`hide`, InstantClose), and only then, behind it, a person's unconfirmed run
/// asks its terminals for a foreground program (`question`). None: the close is sent. One running:
/// the question shows (`ask`); Cancel lists the row again and gives the selection back (`restore`),
/// Close sends it. Before, the question's process-info round trip (up to 1 s per terminal) ran
/// before the row moved, and the handler then resolved the workspace again from whatever window
/// was active, so a slow daemon looked like a press that did nothing.
@MainActor
struct WorkspaceCloseFlow {
    /// Starts the visible close; false when the row stays (the last one of its window's room).
    var hide: @MainActor () -> Bool
    /// The "still running" question, or nil to close without asking.
    var question: @MainActor () async -> DestructiveConfirmation.Prompt?
    /// Shows the question; true when the person chose Close.
    var ask: @MainActor (DestructiveConfirmation.Prompt) async -> Bool
    /// Sends the close (`hidden`: the row left at the press).
    var send: @MainActor (_ hidden: Bool) async -> ActionWorkFailure?
    /// The person cancelled: the row and the selection come back.
    var restore: @MainActor (_ hidden: Bool) -> Void

    /// Workspaces whose close started and has not ended: a second press sends nothing,
    /// also for a row that stayed shown (`hide` false).
    private(set) static var running: Set<String> = []

    /// Starts the close of `id` (`asks`: a person's unconfirmed run); nil while one of it runs.
    func start(_ id: String, asks: Bool) -> ActionWork? {
        guard Self.running.insert(id).inserted else { return nil }
        let hidden = hide()
        return Task { @MainActor in
            defer { Self.running.remove(id) }
            if asks, let prompt = await question(), !(await ask(prompt)) {
                restore(hidden)
                return nil
            }
            return await send(hidden)
        }
    }
}

/// The workspace a window selected when a close's row left (`WorkspaceCloseFlow.hide`), so a
/// cancelled close gives the selection back only while the person has not moved on.
@MainActor
final class WorkspaceCloseSelection {
    var afterPress: String?
}
