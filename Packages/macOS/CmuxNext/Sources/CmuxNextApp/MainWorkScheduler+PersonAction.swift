import CmuxNextWakeups

extension MainWorkScheduler {
    /// Runs the async rest of a person's action: a daemon command's reply, a path check, a page's read.
    ///
    /// `work` starts on the main actor in the order the person's inputs came, so the daemon commands
    /// it sends reach the connection actor in that order (`DaemonCommandBody`). `complete` runs on its
    /// result as soon as it is back, unbudgeted: p06-scheduler.md rule 2 makes the async completion of
    /// a person's action userBlocking (Chrome's `TaskPriority::USER_BLOCKING`, base/task/task_traits.h),
    /// which never waits behind pending input or a spent visible budget. Until that class
    /// (p06-scheduler-208) lands it runs as frame work, as a person-caused observation flush does.
    ///
    /// ```swift
    /// mainWork.personAction(owner: "WorkspaceContent.gestureSettled") {
    ///     await daemon.run(label, body)
    /// } then: { sent in
    ///     sent ? layoutModel.settleTransaction(id) : layoutModel.rejectTransaction(id)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - owner: The completion's owner on the board and in the watchdog's records.
    ///   - work: The async part; it starts now, on the main actor.
    ///   - complete: The main-thread rest of the action, with what `work` returned.
    /// - Returns: The task, which ends after `complete`.
    @discardableResult
    func personAction<T, R: Sendable>(owner: String, _ work: @escaping @MainActor () async -> T,
                                      then complete: @escaping @MainActor (T) -> R) -> Task<R, Never> {
        let budget = budget, board = board
        // main-hop-allow: the rest of a person's action (p06 rule 2): starts in their input order, completes unbudgeted
        return Task {
            let value = await work()
            return budget.run(.frame, owner: board.owner(owner)) { complete(value) }
        }
    }
}
