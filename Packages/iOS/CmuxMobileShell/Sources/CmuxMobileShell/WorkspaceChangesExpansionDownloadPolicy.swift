internal import CmuxMobileChanges

/// Bounds one unchanged-line expansion download independently of remote file churn.
struct WorkspaceChangesExpansionDownloadPolicy: Sendable {
    let byteLimit: Int64
    let maximumChunkCount: Int

    init(byteLimit: Int64, chunkLength: Int) {
        precondition(byteLimit >= 0)
        precondition(chunkLength > 0)
        self.byteLimit = byteLimit
        let fullChunks = byteLimit / Int64(chunkLength)
        let partialChunk = byteLimit % Int64(chunkLength) == 0 ? 0 : 1
        maximumChunkCount = Int(fullChunks + Int64(partialChunk)) + 2
    }

    /// Rejects a response before it can reserve or append beyond the expansion budget.
    func validate(
        totalSize: Int64,
        accumulatedByteCount: Int,
        nextChunkByteCount: Int,
        receivedChunkCount: Int
    ) throws {
        guard totalSize <= byteLimit,
              receivedChunkCount <= maximumChunkCount,
              accumulatedByteCount >= 0,
              nextChunkByteCount >= 0,
              Int64(accumulatedByteCount) <= byteLimit,
              Int64(nextChunkByteCount) <= byteLimit - Int64(accumulatedByteCount) else {
            throw DiffExpansionContentError.tooLarge
        }
    }
}
