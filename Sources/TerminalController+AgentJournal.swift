import Foundation

extension TerminalController {
    /// v1 worker body for `agent_journal_append`: parse and durably commit on
    /// this worker thread (the reply carries the committed sequence — the
    /// emitting hook's durable acknowledgement), with reduction and sidebar
    /// application deferred onto the journal center's ordered consumer.
    nonisolated func agentJournalAppend(_ args: String) -> String {
        AgentJournalLifecycleCenter.shared.handleAppendCommand(args) { draft in
            self.v2MainSync(commandKey: "agent_journal_append") {
                AgentJournalLifecycleCenter.notificationTargetIsCurrent(draft)
            }
        }
    }

    /// v1 worker body for the read-only objective projection query.
    nonisolated func agentJournalGoalQuery(_ args: String) -> String {
        AgentJournalLifecycleCenter.shared.handleGoalQueryCommand(args)
    }
}
