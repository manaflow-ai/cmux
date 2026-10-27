public import CmuxNextActions

/// One Close Workspace, in press order (Lawrence 2026-10-17: "this needs to be instant"). The
/// workspace is the one the press named, fixed then; its row leaves the sidebar and the selection
/// moves in that turn (`hide`, InstantClose), and only then, behind it, a person's unconfirmed run
/// asks its terminals for a foreground program (`question`) and, with one running, the person.
/// Close or nothing running: the close is sent. Cancel lists the row again and gives the selection
/// back (`restore`). Before, the question's process-info round trip (up to 1 s per terminal) ran
/// before the row moved, and the handler then resolved the workspace again from whatever window
/// was active, so a slow daemon looked like a press that did nothing.
@MainActor
public struct WorkspaceCloseFlow {
    /// Starts the visible close; false when the row stays (the last one of its window's room).
    public var hide: @MainActor () -> Bool
    /// Asks the terminals for a running program: nil to close without asking, else the question
    /// to show the person (true: Close).
    public var question: @MainActor () async -> (@MainActor () async -> Bool)?
    /// Whether the workspace is still listed (it may close another way while the question is up).
    public var exists: @MainActor () -> Bool
    /// Queues the close in the window's lane in this turn (`hidden`: the row left at the press).
    public var send: @MainActor (_ hidden: Bool) -> ActionWork
    /// The person cancelled, or the workspace went meanwhile: the row (and the selection) come back.
    public var restore: @MainActor (_ hidden: Bool) -> Void

    public init(hide: @escaping @MainActor () -> Bool, question: @escaping @MainActor () async -> (@MainActor () async -> Bool)?,
                exists: @escaping @MainActor () -> Bool, send: @escaping @MainActor (_ hidden: Bool) -> ActionWork,
                restore: @escaping @MainActor (_ hidden: Bool) -> Void) {
        self.hide = hide
        self.question = question
        self.exists = exists
        self.send = send
        self.restore = restore
    }

    /// Workspaces whose close started and has not ended: a second press sends nothing,
    /// also for a row that stayed shown (`hide` false).
    public private(set) static var running: Set<String> = []

    /// Starts the close of `id` (`asks`: a person's unconfirmed run); nil while one of it runs.
    public func start(_ id: String, asks: Bool) -> ActionWork? {
        guard Self.running.insert(id).inserted else { return nil }
        let hidden = hide()
        // Nothing to ask (a confirmed scripted run): queued in the press's turn, so the close keeps
        // its place among the window's creates and closes (`WorkspaceLanes`).
        guard asks else {
            let work = send(hidden)
            // main-hop-allow: the press's close bookkeeping (`running`) is main-actor state, cleared once the lane's close ends
            return Task { @MainActor in
                defer { Self.running.remove(id) }
                return await work.value
            }
        }
        // main-hop-allow: the person's close in press order: question, the alert and restore are main-actor async seams of the window, read between the terminals' off-main answers (rule 2: the row left in the press's turn)
        return Task { @MainActor in
            defer { Self.running.remove(id) }
            let ask = await question()
            // Gone meanwhile (the CLI, another window): no question for it.
            var closes = exists()
            if closes, let ask { closes = await ask() }
            guard closes, exists() else {
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
public final class WorkspaceCloseSelection {
    public var afterPress: String?

    public init() {}
}
