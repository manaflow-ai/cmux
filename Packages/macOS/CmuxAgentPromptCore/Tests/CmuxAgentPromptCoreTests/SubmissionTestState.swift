import CmuxAgentPromptCore

/// Main-actor observation box for re-entrant delivery and accounting tests.
@MainActor
final class SubmissionTestState {
    var didReenter = false
    var nestedReceipt: AgentPromptSubmissionService.Receipt?
    var deliveryAttempts = 0
}
