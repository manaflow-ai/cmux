/// A lifecycle event emitted by a ``DispatchBackend`` while a card runs.
///
/// The backend reports *raw lifecycle facts* — it does not decide board
/// columns. ``KanbanEngine`` is the single owner of the policy that maps these
/// events onto column transitions (`building → testing → done`, or `→ failed`),
/// so the same backend drives the manual board and autonomous ripping
/// identically.
public enum KanbanDispatchProgress: Sendable, Equatable {
    /// The agent process started; carries the backend's session identifier.
    case started(sessionId: String)
    /// An isolated worktree was provisioned for the run, at `worktreePath` on
    /// branch `branchName`. Emitted at most once, before the first ``output``.
    case provisioned(worktreePath: String, branchName: String)
    /// A line (or chunk) of agent output, destined for the card's log file.
    case output(String)
    /// The agent finished its turn (stopped producing work) but the process may
    /// not have exited yet. Drives the optional `building → testing` gate.
    case turnComplete
    /// The agent process exited with `status` (0 = success).
    case exited(status: Int32)
    /// The run failed before or instead of a clean exit (spawn failure, crash,
    /// backend error); carries a human-readable reason for the log.
    case failed(message: String)
}
