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
    /// Whether the workspace is still listed (it may close another way while the question is up).
    var exists: @MainActor () -> Bool = { true }
    /// Shows the question; true when the person chose Close.
    var ask: @MainActor (DestructiveConfirmation.Prompt) async -> Bool
    /// Queues the close in the window's lane in this turn (`hidden`: the row left at the press).
    var send: @MainActor (_ hidden: Bool) -> ActionWork
    /// The person cancelled, or the workspace went meanwhile: the row (and the selection) come back.
    var restore: @MainActor (_ hidden: Bool) -> Void

    /// Workspaces whose close started and has not ended: a second press sends nothing,
    /// also for a row that stayed shown (`hide` false).
    private(set) static var running: Set<String> = []

    /// Starts the close of `id` (`asks`: a person's unconfirmed run); nil while one of it runs.
    func start(_ id: String, asks: Bool) -> ActionWork? {
        guard Self.running.insert(id).inserted else { return nil }
        let hidden = hide()
        // Nothing to ask (a confirmed scripted run): queued in the press's turn, so the close keeps
        // its place among the window's creates and closes (`WorkspaceLanes`).
        guard asks else {
            let work = send(hidden)
            return Task { @MainActor in
                defer { Self.running.remove(id) }
                return await work.value
            }
        }
        return Task { @MainActor in
            defer { Self.running.remove(id) }
            let prompt = await question()
            var closes = exists()
            if closes, let prompt { closes = await ask(prompt) && exists() }
            guard closes else {
                restore(hidden)
                return nil
            }
            return await send(hidden).value
        }
    }
}

/// The workspace a window selected when a close's row left (`WorkspaceCloseFlow.hide`), so a
/// cancelled close gives the selection back only while the person has not moved on.
@MainActor
final class WorkspaceCloseSelection {
    var afterPress: String?
}
