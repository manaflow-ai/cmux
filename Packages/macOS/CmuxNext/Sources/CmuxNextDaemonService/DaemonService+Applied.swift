import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextWakeups

extension DaemonService {
    /// Runs `body` once the store holds the result of the command that
    /// carried `transaction` (its echo, or every event the daemon emitted
    /// before the reply, which bounds a command that changed nothing). Call
    /// after the command's reply.
    /// `body` keeps the view-change permission of the action run that
    /// called this (`ActionRunScope`), though the store runs it later.
    /// The connection's count is read off main; the rest is one task in the
    /// class of the run's cause (a person's: userBlocking, the rest of their
    /// action; recipe R-hop).
    public func whenApplied(_ transaction: ClientTransactionID, _ body: @escaping @MainActor () -> Void) {
        let run = ActionRunScope.current
        let body = { @MainActor in ActionRunScope.carrying(run, body) }
        guard let connection else { return body() }
        let store = store, mainWork = mainWork
        let workClass = (run?.origin.observationCause ?? .program).budgetedClass
        // task-owner: one actor hop to read the connection's routed event count; finishes at once, nothing to cancel
        Task { @concurrent in
            let barrier = await connection.eventSequence()
            mainWork.postFromAnyThread(workClass, owner: "DaemonService.whenApplied") {
                guard let barrier else { return body() }
                store.whenApplied(transaction, reaching: barrier, body)
            }
        }
    }
}
