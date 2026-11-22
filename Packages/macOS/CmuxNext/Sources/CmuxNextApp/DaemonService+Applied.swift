import CmuxNextActions
import CmuxNextDaemon

extension DaemonService {
    /// Runs `body` once the store holds the result of the command that
    /// carried `transaction` (its echo, or every event the daemon emitted
    /// before the reply, which bounds a command that changed nothing). Call
    /// after the command's reply.
    /// `body` keeps the view-change permission of the action run that
    /// called this (`ActionRunScope`), though the store runs it later.
    func whenApplied(_ transaction: ClientTransactionID, _ body: @escaping @MainActor () -> Void) {
        let run = ActionRunScope.current
        let body = { @MainActor in ActionRunScope.carrying(run, body) }
        guard let connection else { return body() }
        let store = store
        // task-owner: one actor hop to read the connection's routed event count; finishes at once, nothing to cancel
        Task { @MainActor in
            let barrier = await connection.eventSequence()
            guard let barrier else { return body() }
            store.whenApplied(transaction, reaching: barrier, body)
        }
    }
}
