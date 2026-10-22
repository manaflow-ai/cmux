import Foundation

/// A daemon command that reads one chunk of an attachment variant with the
/// local owner's fields: `conversation-attachment-read` and
/// `cloud-attachment-read` answer the same, so one ``AttachmentTransfer``
/// runs both.
protocol AttachmentReadStep: DaemonRequest where Response == ConversationAttachmentReadRequest.Response {
    init(read: ConversationAttachmentReadRequest)
}

extension ConversationAttachmentReadRequest: AttachmentReadStep {
    init(read: ConversationAttachmentReadRequest) { self = read }
}
