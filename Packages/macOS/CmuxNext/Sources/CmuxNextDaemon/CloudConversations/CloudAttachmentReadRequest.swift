import Foundation

/// `cloud-attachment-read` (`cloud-attachments-v1`): up to `length` bytes of
/// one variant of a Cloud conversation's attachment, read by the daemon
/// through a URL the Cloud owner signs, with the same fields and reply as
/// ``ConversationAttachmentReadRequest``.
public struct CloudAttachmentReadRequest: DaemonRequest, AttachmentReadStep {
    public typealias Response = ConversationAttachmentReadRequest.Response
    public static let command = "cloud-attachment-read"
    public static let requiredCapability: String? = DaemonCapability.cloudAttachments.rawValue
    /// The read, encoded as is.
    public var read: ConversationAttachmentReadRequest

    public init(read: ConversationAttachmentReadRequest) {
        self.read = read
    }

    public func encode(to encoder: any Encoder) throws {
        try read.encode(to: encoder)
    }
}
