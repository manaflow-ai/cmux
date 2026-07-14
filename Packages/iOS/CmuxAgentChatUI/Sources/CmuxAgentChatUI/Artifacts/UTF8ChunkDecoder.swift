import Foundation

/// Owns one UTF-8 assembler while an artifact stream crosses actor boundaries.
actor UTF8ChunkDecoder {
    private var assembler = UTF8ChunkAssembler()

    /// Decodes the next raw chunk without moving byte scanning onto the main actor.
    func decode(_ data: Data, eof: Bool) throws -> String {
        try assembler.append(data, eof: eof)
    }
}
