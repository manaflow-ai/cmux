import Foundation

/// Main-actor gate used by service tests to model a temporarily unavailable target.
@MainActor
final class DeliveryGate {
    var isReady = false
}

/// Main-actor observation box for re-entrant delivery and accounting tests.
@MainActor
final class SubmissionTestState {
    var didReenter = false
    var nestedReceipt: AgentPromptSubmissionService.Receipt?
    var deliveryAttempts = 0
}
