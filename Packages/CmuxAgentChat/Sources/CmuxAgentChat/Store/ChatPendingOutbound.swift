import Foundation

/// An optimistic local row for a prompt the user sent that has not yet
/// echoed back through the transcript.
///
/// Lives only in the sending client; once the host's transcript echoes the
/// prompt as a real ``ChatMessage``, the pending row is reconciled away.
public struct ChatPendingOutbound: Identifiable, Sendable, Equatable {
    /// Local-only identity (never travels on the wire).
    public let id: String

    /// The prompt text being sent.
    public let text: String

    /// Number of attachments sent with the prompt.
    public let attachmentCount: Int

    /// When the user hit send.
    public let createdAt: Date

    /// Current delivery progress.
    public var delivery: ChatDeliveryState

    /// Creates a pending outbound row.
    ///
    /// - Parameters:
    ///   - id: Local-only identity.
    ///   - text: The prompt text.
    ///   - attachmentCount: Number of attachments sent with the prompt.
    ///   - createdAt: When the user hit send.
    ///   - delivery: Current delivery progress.
    public init(
        id: String,
        text: String,
        attachmentCount: Int,
        createdAt: Date,
        delivery: ChatDeliveryState
    ) {
        self.id = id
        self.text = text
        self.attachmentCount = attachmentCount
        self.createdAt = createdAt
        self.delivery = delivery
    }
}
