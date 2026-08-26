/// Validates the ordered chunk protocol shared by artifact transports and stores.
public struct ChatArtifactChunkValidator: Sendable {
    private let expectedSize: Int64?
    private var observedSize: Int64?
    private var nextOffset: Int64 = 0
    private var reachedEOF = false
    private var receivedChunk = false

    /// Creates a validator, optionally pinned to metadata fetched before the stream.
    ///
    /// - Parameter expectedSize: The stat-reported size, or `nil` when the first
    ///   chunk establishes the transfer size.
    public init(expectedSize: Int64? = nil) {
        self.expectedSize = expectedSize
    }

    /// Accepts one chunk only when its offset, size, and EOF metadata are coherent.
    public mutating func receive(_ chunk: ChatArtifactChunk) throws {
        guard expectedSize.map({ $0 >= 0 }) ?? true,
              !reachedEOF,
              chunk.offset >= 0,
              chunk.totalSize >= 0,
              chunk.offset == nextOffset else {
            throw ChatArtifactError.invalidResponse
        }
        if let expectedSize, chunk.totalSize != expectedSize {
            throw ChatArtifactError.fileChanged
        }
        if let observedSize, chunk.totalSize != observedSize {
            throw ChatArtifactError.fileChanged
        }
        observedSize = chunk.totalSize

        let byteCount = Int64(chunk.data.count)
        guard byteCount <= chunk.totalSize - chunk.offset else {
            throw ChatArtifactError.invalidResponse
        }
        let endOffset = chunk.offset + byteCount
        if chunk.eof {
            guard endOffset == chunk.totalSize else {
                throw ChatArtifactError.invalidResponse
            }
        } else {
            guard byteCount > 0, endOffset < chunk.totalSize else {
                throw ChatArtifactError.invalidResponse
            }
        }

        receivedChunk = true
        nextOffset = endOffset
        reachedEOF = chunk.eof
    }

    /// Confirms that the producer returned an exact-size EOF chunk before ending.
    public func finish() throws {
        guard receivedChunk, reachedEOF else {
            throw ChatArtifactError.transferInterrupted
        }
    }
}
