import Foundation

/// Owns one UTF-8 assembler while an artifact stream crosses actor boundaries.
actor UTF8ChunkDecoder {
    private var assembler = UTF8ChunkAssembler()
    private let batcher = ChatArtifactTextStreamBatcher()

    /// Decodes and batches the next raw chunk without moving either operation onto the main actor.
    func decodeBatches(_ data: Data, eof: Bool) throws -> [String] {
        let decoded = try assembler.append(data, eof: eof)
        return batcher.batches(for: decoded)
    }
}
