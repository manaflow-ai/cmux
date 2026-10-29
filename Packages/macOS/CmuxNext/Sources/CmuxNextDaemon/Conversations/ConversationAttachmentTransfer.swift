public import Foundation

/// Attachment bytes over one daemon connection (`local-attachments-v1`):
/// chunked uploads by SHA-256 and chunked reads into a local file
/// (``AttachmentTransfer`` with the local owner's commands).
extension ConversationClient {
    /// Decoded bytes per chunk and per read: the daemon's limit (4 MiB, about
    /// 5.6 MiB of base64 inside a 16 MiB request line).
    public static let attachmentChunkBytes = 4 << 20
    /// A chunk's deadline: 4 MiB over a local socket takes milliseconds;
    /// this bounds a stalled daemon, not a slow disk.
    static let attachmentChunkTimeout: Duration = .seconds(30)

    public static func supportsAttachments(_ connection: DaemonConnection) async -> Bool {
        await connection.identity?.supports(DaemonCapability.localAttachments.rawValue) == true
    }

    private func requireAttachments() async throws {
        guard await Self.supportsAttachments(connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.localAttachments.rawValue])
        }
    }

    /// The local owner's steps: `begin` on the connection's default deadline, the others on `attachmentChunkTimeout`.
    private var transfer: AttachmentTransfer<ConversationAttachmentUploadRequest, ConversationAttachmentReadRequest> {
        AttachmentTransfer(connection: connection, beginTimeout: nil, chunkTimeout: Self.attachmentChunkTimeout,
                           commitTimeout: Self.attachmentChunkTimeout, readTimeout: Self.attachmentChunkTimeout)
    }

    /// Uploads `attachment`'s bytes from `file` (and its poster or preview
    /// from `posterFile` / `previewFile`) to `conversation`. A hash the
    /// conversation already holds returns the kept record without sending
    /// bytes. `progress` gets the fraction sent, 0...1. A failure after
    /// `begin` cancels the upload on the daemon (best effort).
    public func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL,
                                 posterFile: URL? = nil, previewFile: URL? = nil,
                                 progress: @Sendable (Double) -> Void = { _ in }) async throws -> StoredConversationAttachment {
        try await requireAttachments()
        return try await transfer.upload(conversation: conversation, attachment: attachment, file: file, posterFile: posterFile,
                                         previewFile: previewFile, progress: progress)
    }

    /// Reads `variant` of `hash` in `conversation` into `destination`
    /// atomically: the bytes land in a temporary file beside it that moves
    /// into place only when complete, so a cancelled read leaves nothing.
    /// Returns the variant's mime type.
    @discardableResult
    public func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                                   to destination: URL) async throws -> String {
        try await requireAttachments()
        return try await transfer.download(conversation: conversation, hash: hash, variant: variant, to: destination)
    }
}
