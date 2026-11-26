import CmuxAgentChat
import Foundation

/// Deterministic chunk source and delivery recorder for fetch-loop tests.
actor MobileArtifactChunkScript {
    private let chunksByOffset: [Int64: ChatArtifactChunk]
    private var requestedOffsets: [Int64] = []
    private var deliveredChunks: [ChatArtifactChunk] = []

    init(chunks: [ChatArtifactChunk]) {
        chunksByOffset = Dictionary(uniqueKeysWithValues: chunks.map { ($0.offset, $0) })
    }

    func fetch(offset: Int64) throws -> ChatArtifactChunk {
        requestedOffsets.append(offset)
        guard let chunk = chunksByOffset[offset] else {
            throw ChatArtifactError.fileNotFound
        }
        return chunk
    }

    func record(_ chunk: ChatArtifactChunk) {
        deliveredChunks.append(chunk)
    }

    func snapshot() -> (requestedOffsets: [Int64], deliveredChunks: [ChatArtifactChunk]) {
        (requestedOffsets, deliveredChunks)
    }
}
