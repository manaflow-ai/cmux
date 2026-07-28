internal import CmuxAgentChat
internal import Foundation

/// Runs the offset-driven artifact fetch protocol for chat and terminal scopes.
struct MobileArtifactChunkFetchLoop: Sendable {
    /// Fetches chunks in sequence until EOF while preserving consumer backpressure.
    ///
    /// - Parameters:
    ///   - collectsData: Whether to return a contiguous copy of all chunk data.
    ///   - progress: Optional byte-progress callback.
    ///   - fetchChunk: Fetches the chunk beginning at the requested byte offset.
    ///   - onChunk: Optionally consumes each response before the next request begins.
    /// - Returns: All fetched bytes when `collectsData` is true; otherwise empty data.
    func run(
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        fetchChunk: @Sendable (_ offset: Int64) async throws -> ChatArtifactChunk,
        onChunk: @Sendable (_ chunk: ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        var offset: Int64 = 0
        var result = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try await fetchChunk(offset)
            try Task.checkCancellation()

            if collectsData {
                if result.isEmpty, chunk.totalSize > 0, chunk.totalSize <= Int64(Int.max) {
                    result.reserveCapacity(Int(chunk.totalSize))
                }
                result.append(chunk.data)
            }
            offset = chunk.offset + Int64(chunk.data.count)
            progress?(offset, chunk.totalSize)
            try await onChunk(chunk)
            if chunk.eof {
                return result
            }
            guard !chunk.data.isEmpty else {
                throw ChatArtifactError.macUnreachable
            }
        }
    }
}
