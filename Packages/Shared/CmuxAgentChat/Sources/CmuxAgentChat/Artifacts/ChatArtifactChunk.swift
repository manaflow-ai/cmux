import Foundation

/// One raw-data chunk returned by the Mac artifact fetch RPC.
public struct ChatArtifactChunk: Sendable, Equatable, Codable {
    /// Raw bytes decoded from the RPC's base64 payload.
    public let data: Data
    /// Byte offset where this chunk begins.
    public let offset: Int64
    /// Total file size in bytes.
    public let totalSize: Int64
    /// Whether this chunk reaches the end of the file.
    public let eof: Bool

    /// Creates a fetch chunk.
    ///
    /// - Parameters:
    ///   - data: Raw bytes in this chunk.
    ///   - offset: Byte offset where the chunk begins.
    ///   - totalSize: Total file size in bytes.
    ///   - eof: Whether this chunk reaches the end of the file.
    public init(data: Data, offset: Int64, totalSize: Int64, eof: Bool) {
        self.data = data
        self.offset = offset
        self.totalSize = totalSize
        self.eof = eof
    }

    private enum CodingKeys: String, CodingKey {
        case data = "data_b64"
        case offset
        case totalSize = "total_size"
        case eof
    }
}
