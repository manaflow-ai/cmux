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
    public var attachmentCount: Int { attachments.count }

    /// The attachment payloads, retained until the send reconciles so a
    /// retry resends them rather than silently dropping images.
    public let attachments: [ChatOutboundAttachment]

    /// When the user hit send.
    public let createdAt: Date

    /// Current delivery progress.
    public var delivery: ChatDeliveryState

    /// Whether a transcript echo may consume this row. Queued sends have not
    /// reached the host yet, and failed sends keep their retry row.
    var isReconcilable: Bool {
        switch delivery {
        case .sending, .delivered:
            return true
        case .queued, .failed:
            return false
        }
    }

    /// Creates a pending outbound row.
    ///
    /// - Parameters:
    ///   - id: Local-only identity.
    ///   - text: The prompt text.
    ///   - attachments: Attachment payloads, kept for retry.
    ///   - createdAt: When the user hit send.
    ///   - delivery: Current delivery progress.
    public init(
        id: String,
        text: String,
        attachments: [ChatOutboundAttachment] = [],
        createdAt: Date,
        delivery: ChatDeliveryState
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.delivery = delivery
    }
}
