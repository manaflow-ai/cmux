public import Foundation

/// The ledger result for one agent prompt-submission hook.
public struct PromptSubmissionConfirmation: Equatable, Sendable {
    /// The ownership class attributed to the hook.
    public let origin: PromptSubmissionConfirmationOrigin
    /// The ledger-owned app message ID, when the hook matched an app prompt.
    public let messageID: UUID?

    /// Creates a prompt-submission confirmation.
    ///
    /// - Parameters:
    ///   - origin: The matched ownership class.
    ///   - messageID: The matching app-owned message ID, if any.
    public init(
        origin: PromptSubmissionConfirmationOrigin,
        messageID: UUID? = nil
    ) {
        self.origin = origin
        self.messageID = messageID
    }
}
