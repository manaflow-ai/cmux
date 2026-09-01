public import CmuxTerminalCore
public import Foundation

/// Identifies one addressed prompt and records its immediate admission result.
public struct AgentPromptSubmissionReceipt: Equatable, Sendable {
    /// The stable ID callers use to correlate delivery lifecycle events.
    public let messageID: UUID

    /// The immediate admission or delivery result.
    public let result: AgentPromptSubmissionResult

    /// Creates a prompt-delivery receipt.
    ///
    /// - Parameters:
    ///   - messageID: The stable request identifier.
    ///   - result: The request's admission result.
    public init(messageID: UUID, result: AgentPromptSubmissionResult) {
        self.messageID = messageID
        self.result = result
    }
}
