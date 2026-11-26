public import Foundation

/// One raw chunk of a mobile task attachment upload.
public struct MobileTaskAttachmentUploadRequest: Equatable, Sendable {
    /// Task idempotency key whose directory owns the attachment.
    public let operationID: UUID
    /// Client-minted attachment identity, stable across retries.
    public let uploadID: UUID
    /// User-visible source file name.
    public let fileName: String
    /// Declared raw byte count for the complete file.
    public let totalBytes: Int
    /// Contiguous raw byte offset for this chunk.
    public let offset: Int
    /// Base64-encoded raw chunk bytes.
    public let dataBase64: String
    /// Whether this chunk completes the upload.
    public let isLast: Bool

    /// Creates an attachment upload request.
    ///
    /// - Parameters:
    ///   - operationID: Task idempotency key.
    ///   - uploadID: Stable attachment upload identity.
    ///   - fileName: User-visible source file name.
    ///   - totalBytes: Complete raw file byte count.
    ///   - offset: Contiguous raw byte offset.
    ///   - dataBase64: Base64-encoded raw chunk.
    ///   - isLast: Whether this is the final chunk.
    public init(
        operationID: UUID,
        uploadID: UUID,
        fileName: String,
        totalBytes: Int,
        offset: Int,
        dataBase64: String,
        isLast: Bool
    ) {
        self.operationID = operationID
        self.uploadID = uploadID
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.offset = offset
        self.dataBase64 = dataBase64
        self.isLast = isLast
    }
}
