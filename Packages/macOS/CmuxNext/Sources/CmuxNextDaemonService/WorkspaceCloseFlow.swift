public import CmuxNextActions

/// One Close Workspace, in press order (Lawrence 2026-10-17: "this needs to be instant"). The
/// workspace is the one the press named, fixed then. A close whose store shows a terminal that may
/// run a program (`mayAsk`) keeps its row in place while its terminals answer process-info
/// (`question`) and while the person answers the question; the row leaves only after Close (or when
/// nothing runs), and Cancel leaves it where it was. Before, the row animated away first and the
/// question came up behind it. Any other close leaves the sidebar and moves the selection in the
/// press's turn (`hide`, InstantClose); a person's run still asks its terminals behind it, since the
/// store can read a prompt while a program runs (ssh, a nested shell), and in that rare case Cancel
/// lists the row again (`restore`). A confirmed scripted run never asks.
@MainActor
public struct WorkspaceCloseFlow {
    /// Starts the visible close; false when the row stays (the last one of its window's room).
    public var hide: @MainActor () -> Bool
    /// Whether a person's run will likely ask, read in the press's turn from the store (a live
    /// terminal not at its prompt, the warning on). True: the row stays until the answer.
    public var mayAsk: @MainActor () -> Bool
    /// Asks the terminals for a running program: nil to close without asking, else the question
    /// to show the person (true: Close).
    public var question: @MainActor () async -> (@MainActor () async -> Bool)?
    /// Whether the workspace is still listed (it may close another way while the question is up).
    public var exists: @MainActor () -> Bool
    /// Queues the close in the window's lane in this turn (`hidden`: the row left).
    public var send: @MainActor (_ hidden: Bool) -> ActionWork
    /// A row that left at the press was cancelled, or its workspace went meanwhile: the row (and the
    /// selection) come back.
    public var restore: @MainActor (_ hidden: Bool) -> Void

    public init(hide: @escaping @MainActor () -> Bool, mayAsk: @escaping @MainActor () -> Bool,
                question: @escaping @MainActor () async -> (@MainActor () async -> Bool)?,
                exists: @escaping @MainActor () -> Bool, send: @escaping @MainActor (_ hidden: Bool) -> ActionWork,
                restore: @escaping @MainActor (_ hidden: Bool) -> Void) {
        self.hide = hide
        self.mayAsk = mayAsk
        self.question = question
        self.exists = exists
        self.send = send
        self.restore = restore
    }

    /// Workspaces whose close started and has not ended: a second press sends nothing,
    /// also for a row that stayed shown (`hide` false, or a question still up).
    public private(set) static var running: Set<String> = []

    /// Starts the close of `id` (`asks`: a person's unconfirmed run); nil while one of it runs.
    public func start(_ id: String, asks: Bool) -> ActionWork? {
        guard Self.running.insert(id).inserted else { return nil }
        // Nothing to ask (a confirmed scripted run): the row leaves and the close is queued in the
        // press's turn, so it keeps its place among the window's creates and closes (`WorkspaceLanes`).
        guard asks else {
            let work = send(hide())
            return Task { @MainActor in
                defer { Self.running.remove(id) }
                return await work.value
            }
        }
        // The question likely shows: the row stays put until it is answered. Else it leaves now.
        let early = mayAsk() ? nil : hide()
        return Task { @MainActor in
            defer { Self.running.remove(id) }
            let ask = await question()
            // Gone meanwhile (the CLI, another window): no question for it, nothing to send.
            var closes = exists()
            if closes, let ask { closes = await ask() }
            guard closes, exists() else {
                // Cancel on a row that never moved: nothing to bring back.
                if let early { restore(early) }
                return nil
            }
            return await send(early ?? hide()).value
        }
    }
}

extension WorkspaceCloseFlow {
    /// Starts the close of `id` (`start(_:asks:)`) and says what the press's turn showed, as the action's effect
    /// (plans/cmux-next/zero-latency.md, "Native actions: the budget contract"):
    /// - the row left and the selection moved in the turn: `.applied`. The registry follows the close and, when the
    ///   daemon refuses it, runs `takeBack` (the row lists again and its window says why) and reports it. The failure
    ///   is marked shown: `takeBack` says why, so no reporter says it a second time.
    /// - a terminal may run a program, so the row stays for the question: `.waiting(.externalProcess)`.
    /// - the last row of its window's room, which cannot leave alone: `.waiting(.daemonEcho)`.
    /// The registry counts the two waits; `takeBack` runs for them too when their row left later (after the answer).
    ///
    /// The close is queued in the window's lane in this turn (`send`), not by the registry a hop later: it must keep
    /// its place among the creates and closes pressed before it (`WorkspaceLanes`, cx-7cit9). The registry awaits
    /// that queued work. Nil from `start` (a close of `id` runs already) is `.done`.
    ///
    /// - Parameters:
    ///   - id: The workspace, fixed at the press.
    ///   - asks: A person's unconfirmed run.
    ///   - takeBack: Lists the row again and says why; called only for a refused close whose row left.
    public func effect(_ id: String, asks: Bool, takeBack: @escaping @MainActor (ActionWorkFailure) -> Void) -> ActionEffect {
        let press = WorkspaceCloseSelection()
        var flow = self
        flow.hide = { [hide] in
            let hidden = hide()
            press.hidden = hidden
            return hidden
        }
        guard let work = flow.start(id, asks: asks) else { return .done }
        let closed: @MainActor () async -> ActionWorkFailure? = {
            guard var failure = await work.value else { return nil }
            if press.hidden == true { failure.shown = true }
            return failure
        }
        let rollback: @MainActor (ActionWorkFailure) -> Void = { failure in
            if press.hidden == true { takeBack(failure) }
        }
        if press.hidden == true { return .applied(ActionConfirmation(send: closed, rollback: rollback)) }
        let waited: @MainActor () async -> ActionWorkFailure? = {
            guard let failure = await closed() else { return nil }
            rollback(failure)
            return failure
        }
        if press.hidden == nil {
            // action-wait-allow: a terminal may run a program: the row must stay until its terminals answer process-info and the person answers the question (the row never leaves before its question)
            return .waiting(.externalProcess, waited)
        }
        // action-wait-allow: the last row of its window's room cannot leave alone (a window is never empty, ClosingWorkspaces.begin): its window closes at the daemon's echo. Debt: close that window at the press.
        return .waiting(.daemonEcho, waited)
    }
}

/// The workspace a window selected when a close's row left (`WorkspaceCloseFlow.hide`), so a
/// cancelled close gives the selection back only while the person has not moved on.
@MainActor
public final class WorkspaceCloseSelection {
    public var afterPress: String?
    /// Whether the row left when `hide` ran (false: the last row of its window's room stayed). Nil until `hide` runs:
    /// a question that may show keeps the row until its answer.
    public var hidden: Bool?

    public init() {}
}
