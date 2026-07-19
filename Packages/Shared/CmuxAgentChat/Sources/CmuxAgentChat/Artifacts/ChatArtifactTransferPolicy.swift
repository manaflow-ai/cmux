/// Transfer limits shared by Mac artifact RPC handlers and iOS preview code.
public struct ChatArtifactTransferPolicy: Sendable, Equatable {
    /// Default artifact transfer policy.
    public static let defaultPolicy = ChatArtifactTransferPolicy()

    /// Maximum raw bytes returned by one fetch RPC chunk.
    public let maxRawChunkBytes: Int
    /// Maximum mobile-sync frame size the chunk envelope must remain below.
    public let mobileSyncFrameLimitBytes: Int
    /// Maximum file size the iOS viewer previews inline.
    public let maxPreviewBytes: Int64

    /// Creates an artifact transfer policy.
    ///
    /// - Parameters:
    ///   - maxRawChunkBytes: Maximum raw bytes returned by one fetch chunk.
    ///   - mobileSyncFrameLimitBytes: Maximum mobile-sync frame size.
    ///   - maxPreviewBytes: Maximum inline preview file size.
    public init(
        maxRawChunkBytes: Int = 3 * 1024 * 1024,
        mobileSyncFrameLimitBytes: Int = 8 * 1024 * 1024,
        maxPreviewBytes: Int64 = 64 * 1024 * 1024
    ) {
        self.maxRawChunkBytes = maxRawChunkBytes
        self.mobileSyncFrameLimitBytes = mobileSyncFrameLimitBytes
        self.maxPreviewBytes = maxPreviewBytes
    }

    /// Clamps a requested chunk length to the policy's raw-byte maximum.
    ///
    /// - Parameter requestedLength: Optional client-requested byte count.
    /// - Returns: A positive chunk length no larger than ``maxRawChunkBytes``.
    public func clampedChunkLength(_ requestedLength: Int?) -> Int {
        guard let requestedLength, requestedLength > 0 else {
            return maxRawChunkBytes
        }
        return min(requestedLength, maxRawChunkBytes)
    }

    /// Estimates base64-plus-envelope bytes for a raw chunk.
    ///
    /// - Parameter rawByteCount: Raw chunk byte count.
    /// - Returns: Conservative encoded payload size including JSON overhead.
    public func estimatedEnvelopeByteCount(rawByteCount: Int) -> Int {
        let base64Bytes = ((rawByteCount + 2) / 3) * 4
        return base64Bytes + 1024
    }
}
