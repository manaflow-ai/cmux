/// Progress returned after one mobile task attachment chunk.
public struct MobileTaskAttachmentUploadResult: Equatable, Sendable {
    /// Raw bytes durably staged after this request.
    public let receivedBytes: Int
    /// Final absolute path when the upload completed, otherwise `nil`.
    public let path: String?

    /// Creates an upload result.
    ///
    /// - Parameters:
    ///   - receivedBytes: Raw bytes durably staged.
    ///   - path: Final absolute path after completion.
    public init(receivedBytes: Int, path: String?) {
        self.receivedBytes = receivedBytes
        self.path = path
    }
}
