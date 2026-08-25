import Dispatch
import Foundation

/// Bounds one config include traversal by path count and decoded bytes.
nonisolated struct GitConfigTraversalBudget: Sendable {
    var remainingPathCount: Int
    var remainingFileCount: Int
    var remainingByteCount: Int
    var didEncounterOversizedFile = false
    var didExhaustBudget = false
    let reader: GitConfigFileReader
    let maximumFileByteCount: Int
    let deadline: DispatchTime? = nil

    var isExpired: Bool {
        guard let deadline else { return false }
        return deadline <= DispatchTime.now()
    }

    mutating func reservePath() -> Bool {
        guard !isExpired, remainingPathCount > 0 else {
            didExhaustBudget = true
            return false
        }
        remainingPathCount -= 1
        return true
    }

    mutating func read(at url: URL) -> String? {
        guard !isExpired, remainingFileCount > 0, remainingByteCount > 0 else {
            didExhaustBudget = true
            return nil
        }
        remainingFileCount -= 1
        switch reader.read(
            at: url,
            maximumByteCount: min(remainingByteCount, maximumFileByteCount),
            deadline: deadline
        ) {
        case .contents(let contents, consumedByteCount: byteCount):
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return contents
        case .oversized(let byteCount):
            didEncounterOversizedFile = true
            didExhaustBudget = true
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        case .missing:
            return nil
        case .unavailable(let byteCount):
            didExhaustBudget = true
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        }
    }
}
