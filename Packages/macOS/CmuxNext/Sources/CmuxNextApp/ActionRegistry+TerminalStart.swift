import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService

extension ActionRegistry {
    /// Follows the start of the terminal `reply` made, once action `id` answered at that reply
    /// (`terminal-async-start-v1`, ``StartingTerminal``): the keys, focus and sizing of the action
    /// resolved at the reply, so only a start that failed is left to say. The daemon rolls back the
    /// tab or pane it made, and the refusal HUD says why (``ActionFollowUp``). A reply that
    /// came after the start has nothing to follow.
    ///
    /// - Parameters:
    ///   - reply: The reply of the command that made the terminal.
    ///   - id: The action that made it.
    func followStart(of reply: StartingTerminal, after id: ActionID) {
        guard reply.isStarting else { return }
        ActionFollowUp(self).run(id) {
            await reply.outcome().failure.map { ActionWorkFailure(RefusalStrings.terminalDidNotStart($0.reason)) }
        }
    }
}
