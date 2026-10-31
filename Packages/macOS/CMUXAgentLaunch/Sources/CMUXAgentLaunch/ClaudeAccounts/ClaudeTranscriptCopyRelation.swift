import Foundation

/// How two account copies of one Claude transcript relate, byte for byte.
///
/// Claude Code only appends to a transcript, so a copy that is a byte prefix of the other is that
/// conversation at an earlier point, and the longer copy holds every turn of the shorter one.
/// Copies where neither is a prefix of the other went on separately under both accounts.
enum ClaudeTranscriptCopyRelation: Equatable {
    /// Both copies hold the same bytes.
    case identical
    /// The target is a strict prefix of the source: the source has turns the target lacks.
    case sourceIsAhead
    /// The source is a strict prefix of the target: the target has turns the source lacks.
    case targetIsAhead
    /// Neither copy is a prefix of the other; replacing either one would lose turns.
    case diverged

    private static let chunkSize = 64 * 1024

    /// Compares the copies at `sourcePath` and `targetPath`, reading both in chunks up to the
    /// shorter one's size, so the cost is linear in that size. Sizes are read first, so bytes a
    /// writer appends during the comparison are not compared.
    init(sourcePath: String, targetPath: String) throws {
        let sourceSize = try Self.size(ofFileAt: sourcePath)
        let targetSize = try Self.size(ofFileAt: targetPath)
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
        defer { try? source.close() }
        let target = try FileHandle(forReadingFrom: URL(fileURLWithPath: targetPath))
        defer { try? target.close() }

        var remaining = min(sourceSize, targetSize)
        while remaining > 0 {
            let count = Int(min(UInt64(Self.chunkSize), remaining))
            let sourceChunk = try source.read(upToCount: count) ?? Data()
            let targetChunk = try target.read(upToCount: count) ?? Data()
            // A copy that shrank under us is no longer the prefix it was measured as.
            guard sourceChunk.count == count, targetChunk.count == count, sourceChunk == targetChunk else {
                self = .diverged
                return
            }
            remaining -= UInt64(count)
        }
        if sourceSize == targetSize {
            self = .identical
        } else {
            self = sourceSize > targetSize ? .sourceIsAhead : .targetIsAhead
        }
    }

    private static func size(ofFileAt path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
