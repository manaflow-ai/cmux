import Foundation

/// `cloud-attachment-upload` (`cloud-attachments-v1`): one step of a chunked
/// upload to a Cloud conversation, with the same fields and replies as
/// ``ConversationAttachmentUploadRequest``. The daemon asks the Cloud owner
/// for the slot with its lease and carries the bytes; `commit` sends them.
/// Use `CloudConversationClient.uploadAttachment`, which runs the whole upload.
public struct CloudAttachmentUploadRequest: DaemonRequest, AttachmentUploadStep {
    public typealias Response = ConversationAttachmentUploadRequest.Response
    public static let command = "cloud-attachment-upload"
    public static let requiredCapability: String? = DaemonCapability.cloudAttachments.rawValue
    /// The step, encoded as is.
    public var step: ConversationAttachmentUploadRequest

    public init(step: ConversationAttachmentUploadRequest) {
        self.step = step
    }

    public func encode(to encoder: any Encoder) throws {
        try step.encode(to: encoder)
    }
}
