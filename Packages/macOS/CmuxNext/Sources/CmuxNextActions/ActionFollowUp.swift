import CmuxNextWakeups

/// The part of an action that ends after the action answered: a terminal start the daemon reports
/// after the reply that showed its tab (`terminal-async-start-v1`, p05-ipc-131). The action's own work
/// (``ActionRegistry/track(_:)``) ended at the reply, so a capturing caller had its answer and the
/// input's response closed then; nobody awaits this. Its failure, which the work's owner rolled back,
/// always shows where an ``ActionEffect/applied(_:)`` failure shows
/// (``ActionRegistry/remoteFailureObserver``), with the same notice.
public struct ActionFollowUp {
    private let registry: ActionRegistry

    /// - Parameter registry: The registry whose failure notice shows the follow-up's failure.
    public init(_ registry: ActionRegistry) {
        self.registry = registry
    }

    /// Runs `work` for action `id`. Call it from the run, or a task the run started, so its failure
    /// notice keeps the run's cause.
    ///
    /// - Parameters:
    ///   - id: The action whose answer the work follows.
    ///   - work: The rest of the action; nil on success, else the failure.
    public func run(_ id: ActionID, _ work: @escaping @MainActor () async -> ActionWorkFailure?) {
        let cause = (ActionRunScope.current?.origin ?? .user).observationCause
        let title = registry.title(for: id) ?? id.rawValue
        let mainWork = registry.mainWork
        // task-owner: nobody awaits a follow-up; it ends with `work`, which is bounded (TerminalStartWatch's start deadline)
        // main-hop-allow: `work` is main-actor async; its failure notice is posted through mainWork.reply in the run's class
        Task { [weak registry] in
            guard let failure = await work() else { return }
            let show: @MainActor () -> Void = { registry?.remoteFailureObserver?(id, failedText(title, failure.message)) }
            if let mainWork {
                await mainWork.reply(as: cause, owner: "ActionFollowUp.failure") { show() }
            } else {
                show()
            }
        }
    }
}
