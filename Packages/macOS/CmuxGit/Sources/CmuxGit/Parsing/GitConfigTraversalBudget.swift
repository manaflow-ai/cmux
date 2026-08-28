import Dispatch
import Foundation

/// Bounds one config include traversal by path count and decoded bytes.
nonisolated struct GitConfigTraversalBudget: Sendable {
    var remainingPathCount: Int
    var remainingFileCount: Int
    var remainingByteCount: Int
    var didEncounterOversizedFile = false
    var didEncounterUnsafeFile = false
    var didExhaustBudget = false
    let reader: GitConfigFileReader
    let maximumFileByteCount: Int
    let deadline: DispatchTime?

    init(
        remainingPathCount: Int,
        remainingFileCount: Int,
        remainingByteCount: Int,
        reader: GitConfigFileReader,
        maximumFileByteCount: Int,
        deadline: DispatchTime? = nil
    ) {
        self.remainingPathCount = remainingPathCount
        self.remainingFileCount = remainingFileCount
        self.remainingByteCount = remainingByteCount
        self.reader = reader
        self.maximumFileByteCount = maximumFileByteCount
        self.deadline = deadline
    }

    var isExpired: Bool {
        if WorkspaceChangesCancellationSignal.isCurrentCancelled {
            return true
        }
        guard let deadline else { return false }
        return deadline <= DispatchTime.now()
    }

    mutating func canReservePath() -> Bool {
        guard !isExpired, remainingPathCount > 0 else {
            didExhaustBudget = true
            return false
        }
        return true
    }

    mutating func reservePath() -> Bool {
        guard canReservePath() else { return false }
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
        case let .contents(contents, consumedByteCount: byteCount):
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return contents
        case let .oversized(byteCount):
            didEncounterOversizedFile = true
            didExhaustBudget = true
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        case .missing:
            return nil
        case let .unavailable(byteCount):
            didEncounterUnsafeFile = true
            didExhaustBudget = true
            remainingByteCount = max(0, remainingByteCount - byteCount)
            return nil
        }
    }
}
