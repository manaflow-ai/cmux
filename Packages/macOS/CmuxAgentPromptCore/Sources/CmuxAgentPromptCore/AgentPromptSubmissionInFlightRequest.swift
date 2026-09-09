import Foundation

/// Tracks the ordering barrier for the most recently accepted prompt.
struct AgentPromptSubmissionInFlightRequest {
    let messageID: UUID
    var surfaceID: UUID?
    var acceptedAt: Date
    var didConfirm: Bool
}
