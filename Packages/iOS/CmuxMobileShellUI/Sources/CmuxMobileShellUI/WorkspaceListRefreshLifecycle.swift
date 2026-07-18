#if os(iOS)
import Foundation

/// Orders refresh-driven table snapshots ahead of the native refresh collapse.
struct WorkspaceListRefreshLifecycle {
    struct RefreshID: Equatable {
        fileprivate let rawValue: UInt64
    }

    struct SnapshotApplyID: Equatable {
        fileprivate let rawValue: UInt64
    }

    struct CollapseID: Equatable {
        fileprivate let rawValue: UInt64
    }

    private enum Phase: Equatable {
        case idle
        case refreshing(id: RefreshID, targetGeneration: UInt64)
        case awaitingFinalSnapshot(
            id: RefreshID,
            targetGeneration: UInt64,
            latestApplyID: SnapshotApplyID?
        )
        case collapseScheduled(id: CollapseID)
        case collapsing(id: CollapseID)
    }

    private var phase: Phase = .idle
    private var nextRefreshRawValue: UInt64 = 0
    private var nextApplyRawValue: UInt64 = 0
    private var nextCollapseRawValue: UInt64 = 0

    var suppressesSnapshotAnimations: Bool {
        phase != .idle
    }

    mutating func begin(currentGeneration: UInt64) -> RefreshID? {
        guard phase == .idle else { return nil }
        nextRefreshRawValue &+= 1
        let id = RefreshID(rawValue: nextRefreshRawValue)
        phase = .refreshing(id: id, targetGeneration: currentGeneration &+ 1)
        return id
    }

    mutating func refreshActionCompleted(_ id: RefreshID) -> Bool {
        guard case .refreshing(let activeID, let targetGeneration) = phase,
              activeID == id else {
            return false
        }
        phase = .awaitingFinalSnapshot(
            id: id,
            targetGeneration: targetGeneration,
            latestApplyID: nil
        )
        return true
    }

    mutating func snapshotApplyStarted(
        refreshCompletionGeneration: UInt64
    ) -> SnapshotApplyID? {
        guard case .awaitingFinalSnapshot(
            let id,
            let targetGeneration,
            _
        ) = phase, refreshCompletionGeneration == targetGeneration else {
            return nil
        }
        nextApplyRawValue &+= 1
        let applyID = SnapshotApplyID(rawValue: nextApplyRawValue)
        phase = .awaitingFinalSnapshot(
            id: id,
            targetGeneration: targetGeneration,
            latestApplyID: applyID
        )
        return applyID
    }

    mutating func snapshotApplyCompleted(_ applyID: SnapshotApplyID) -> CollapseID? {
        guard case .awaitingFinalSnapshot(
            _,
            _,
            let latestApplyID
        ) = phase, latestApplyID == applyID else {
            return nil
        }
        nextCollapseRawValue &+= 1
        let collapseID = CollapseID(rawValue: nextCollapseRawValue)
        phase = .collapseScheduled(id: collapseID)
        return collapseID
    }

    mutating func collapseStarted(_ id: CollapseID) -> Bool {
        guard case .collapseScheduled(let activeID) = phase,
              activeID == id else {
            return false
        }
        phase = .collapsing(id: id)
        return true
    }

    mutating func collapseCompleted(_ id: CollapseID) -> Bool {
        guard case .collapsing(let activeID) = phase,
              activeID == id else {
            return false
        }
        phase = .idle
        return true
    }

    mutating func cancelRefresh(_ id: RefreshID) -> Bool {
        guard case .refreshing(let activeID, _) = phase,
              activeID == id else {
            return false
        }
        phase = .idle
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}
#endif
