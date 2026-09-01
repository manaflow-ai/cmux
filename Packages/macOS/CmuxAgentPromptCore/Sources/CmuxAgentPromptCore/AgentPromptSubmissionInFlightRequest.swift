import Foundation

/// Tracks the ordering barrier for the most recently accepted prompt.
struct AgentPromptSubmissionInFlightRequest {
    let messageID: UUID
    let surfaceID: UUID
    let acceptedAt: Date
}
