import Foundation

/// A daemon command that carries one step of a chunked attachment upload
/// (`begin`, `chunk`, `commit`, `cancel`) with the local owner's fields:
/// `conversation-attachment-upload` and `cloud-attachment-upload` take the
/// same steps, so one ``AttachmentTransfer`` runs both.
protocol AttachmentUploadStep: DaemonRequest where Response == ConversationAttachmentUploadRequest.Response {
    init(step: ConversationAttachmentUploadRequest)
}

extension ConversationAttachmentUploadRequest: AttachmentUploadStep {
    init(step: ConversationAttachmentUploadRequest) { self = step }
}
