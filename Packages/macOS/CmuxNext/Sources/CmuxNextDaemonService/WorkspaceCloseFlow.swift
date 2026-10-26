public import CmuxNextActions

/// One Close Workspace, in press order (Lawrence 2026-10-17: "this needs to be instant"). The
/// workspace is the one the press named, fixed then. A close that cannot ask (`mayAsk` false: no
/// live terminal, the warning off, or a confirmed scripted run) leaves the sidebar and moves the
/// selection in the press's turn (`hide`, InstantClose) and is sent. One that may ask keeps its row
/// in place while its terminals answer process-info (`question`) and while the person answers the
/// question; the row leaves only after Close (or when nothing runs), and Cancel leaves it where it
/// was. Before, the row animated away first and the question came up behind it, so Cancel had to
/// bring back a row the person had watched leave.
@MainActor
public struct WorkspaceCloseFlow {
    /// Starts the visible close; false when the row stays (the last one of its window's room).
    public var hide: @MainActor () -> Bool
    /// Whether a person's run can ask at all, read in the press's turn without the daemon (a live
    /// terminal and the warning on). False: the row leaves at once.
    public var mayAsk: @MainActor () -> Bool
    /// Asks the terminals for a running program: nil to close without asking, else the question
    /// to show the person (true: Close).
    public var question: @MainActor () async -> (@MainActor () async -> Bool)?
    /// Whether the workspace is still listed (it may close another way while the question is up).
    public var exists: @MainActor () -> Bool
    /// Queues the close in the window's lane in this turn (`hidden`: the row left).
    public var send: @MainActor (_ hidden: Bool) -> ActionWork

    public init(hide: @escaping @MainActor () -> Bool, mayAsk: @escaping @MainActor () -> Bool,
                question: @escaping @MainActor () async -> (@MainActor () async -> Bool)?,
                exists: @escaping @MainActor () -> Bool, send: @escaping @MainActor (_ hidden: Bool) -> ActionWork) {
        self.hide = hide
        self.mayAsk = mayAsk
        self.question = question
        self.exists = exists
        self.send = send
    }

    /// Workspaces whose close started and has not ended: a second press sends nothing,
    /// also for a row that stayed shown (`hide` false, or a question still up).
    public private(set) static var running: Set<String> = []

    /// Starts the close of `id` (`asks`: a person's unconfirmed run); nil while one of it runs.
    public func start(_ id: String, asks: Bool) -> ActionWork? {
        guard Self.running.insert(id).inserted else { return nil }
        // Nothing to ask: the row leaves and the close is queued in the press's turn, so it keeps
        // its place among the window's creates and closes (`WorkspaceLanes`).
        guard asks, mayAsk() else {
            let work = send(hide())
            return Task { @MainActor in
                defer { Self.running.remove(id) }
                return await work.value
            }
        }
        return Task { @MainActor in
            defer { Self.running.remove(id) }
            let ask = await question()
            // Gone meanwhile (the CLI, another window): no question for it, nothing to send.
            guard exists() else { return nil }
            // Cancel: the row never moved, so there is nothing to bring back.
            if let ask { guard await ask(), exists() else { return nil } }
            return await send(hide()).value
        }
    }
}
