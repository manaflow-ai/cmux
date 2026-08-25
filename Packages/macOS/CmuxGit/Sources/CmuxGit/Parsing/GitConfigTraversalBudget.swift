import Foundation

/// Bounds one config include traversal by path count and decoded bytes.
nonisolated struct GitConfigTraversalBudget: Sendable {
    var remainingPathCount: Int
    var remainingFileCount: Int
    var remainingByteCount: Int
    var didEncounterOversizedFile = false
    let reader: GitConfigFileReader

    mutating func reservePath() -> Bool {
        guard remainingPathCount > 0 else { return false }
        remainingPathCount -= 1
        return true
    }

    mutating func read(at url: URL) -> String? {
        guard remainingFileCount > 0, remainingByteCount > 0 else { return nil }
        remainingFileCount -= 1
        switch reader.read(at: url, maximumByteCount: remainingByteCount) {
        case .contents(let contents, consumedByteCount: byteCount):
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return contents
        case .oversized(let byteCount):
            didEncounterOversizedFile = true
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        case .unavailable(let byteCount):
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        }
    }
}
