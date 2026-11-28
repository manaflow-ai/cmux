/// Chunk boundaries for one task-attachment upload.
public struct MobileTaskAttachmentChunkPlan: Equatable, Sendable {
    /// Raw-byte ceiling that keeps a base64 RPC payload below the mobile frame cap.
    public static let defaultChunkByteCount = 3 * 1024 * 1024

    /// Total raw bytes to upload.
    public let totalByteCount: Int
    /// Maximum raw bytes in one chunk.
    public let chunkByteCount: Int

    /// Creates a validated chunk plan.
    ///
    /// - Parameters:
    ///   - totalByteCount: Total raw bytes in the attachment.
    ///   - chunkByteCount: Maximum raw bytes in one RPC chunk.
    public init(
        totalByteCount: Int,
        chunkByteCount: Int = Self.defaultChunkByteCount
    ) {
        precondition(totalByteCount >= 0)
        precondition(chunkByteCount > 0)
        self.totalByteCount = totalByteCount
        self.chunkByteCount = chunkByteCount
    }

    /// Ordered byte ranges to send.
    ///
    /// An empty attachment still produces one empty terminal chunk so the host
    /// can finalize and return its path.
    public var ranges: [Range<Int>] {
        guard totalByteCount > 0 else { return [0..<0] }
        return stride(from: 0, to: totalByteCount, by: chunkByteCount).map { offset in
            offset..<min(offset + chunkByteCount, totalByteCount)
        }
    }
}
