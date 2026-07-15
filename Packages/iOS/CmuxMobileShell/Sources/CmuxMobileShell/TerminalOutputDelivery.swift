import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

struct TerminalScrollReconciliation: Equatable, Sendable {
    let interactionEpoch: UInt64
    let clientRevision: UInt64
}

struct TerminalScrollReconciliationSupersession: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case replacement
        case policyInvalidation
    }

    let reconciliation: TerminalScrollReconciliation
    let reason: Reason
}

@MainActor
final class TerminalSurfaceMutationReceipt: Sendable {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var value: Bool {
        get async {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }
}

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    enum ReplacementScope: Equatable, Sendable {
        case byteViewport
        case renderGridViewport
        case viewportPolicy
    }

    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(TerminalPreparedRenderGrid)
        case localScroll([MobileTerminalScrollRun])
        case scrollToBottom
        case barrier
    }

    let deliveryID: UUID
    private var payload: Payload
    private var receipts: [TerminalSurfaceMutationReceipt]
    var replacementScope: ReplacementScope?
    var viewportPolicy: MobileTerminalOutputViewportPolicy?
    var scrollReconciliation: TerminalScrollReconciliation?
    var followingScrollRuns: [MobileTerminalScrollRun]
    /// An explicit authoritative viewport position. `nil` preserves the local
    /// position; `.some(0)` snaps to the bottom after a full history rebuild.
    var scrollbackOffsetFromBottomRows: Int?
    /// Exact line count replayed into a full primary-screen reconstruction.
    /// The consumer rejects the delivery when Ghostty exposes a different row
    /// space instead of positioning against incomplete or reflowed content.
    var authoritativeReconstructedRowCount: Int?

    var replaceable: Bool {
        replacementScope != nil
    }

    init(
        deliveryID: UUID = UUID(),
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollbackOffsetFromBottomRows: Int? = nil
    ) {
        self.deliveryID = deliveryID
        self.payload = .bytes(bytes)
        self.receipts = []
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.scrollReconciliation = nil
        self.followingScrollRuns = []
        self.scrollbackOffsetFromBottomRows = scrollbackOffsetFromBottomRows.map { max(0, $0) }
        self.authoritativeReconstructedRowCount = nil
    }

    init(
        deliveryID: UUID = UUID(),
        renderGrid frame: MobileTerminalRenderGridFrame,
        preparedBytes: Data? = nil,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollReconciliation: TerminalScrollReconciliation? = nil,
        followingScrollRuns: [MobileTerminalScrollRun] = []
    ) {
        self.deliveryID = deliveryID
        self.payload = .renderGrid(TerminalPreparedRenderGrid(
            frame: frame,
            bytes: preparedBytes
        ))
        self.receipts = []
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.scrollReconciliation = scrollReconciliation
        self.followingScrollRuns = followingScrollRuns
        self.scrollbackOffsetFromBottomRows = frame.full && frame.activeScreen == .primary
            ? frame.scrollForwardRows + frame.primaryActiveRows
            : nil
        self.authoritativeReconstructedRowCount = frame.full && frame.activeScreen == .primary
            ? frame.scrollbackRows + frame.rows + frame.scrollForwardRows + frame.primaryActiveRows
            : nil
    }

    init(
        deliveryID: UUID = UUID(),
        localScroll runs: [MobileTerminalScrollRun],
        receipt: TerminalSurfaceMutationReceipt
    ) {
        self.deliveryID = deliveryID
        self.payload = .localScroll(runs)
        self.receipts = [receipt]
        self.replacementScope = nil
        self.viewportPolicy = nil
        self.scrollReconciliation = nil
        self.followingScrollRuns = []
        self.scrollbackOffsetFromBottomRows = nil
        self.authoritativeReconstructedRowCount = nil
    }

    init(
        deliveryID: UUID = UUID(),
        scrollToBottomReceipt receipt: TerminalSurfaceMutationReceipt
    ) {
        self.deliveryID = deliveryID
        self.payload = .scrollToBottom
        self.receipts = [receipt]
        self.replacementScope = nil
        self.viewportPolicy = nil
        self.scrollReconciliation = nil
        self.followingScrollRuns = []
        self.scrollbackOffsetFromBottomRows = nil
        self.authoritativeReconstructedRowCount = nil
    }

    init(
        deliveryID: UUID = UUID(),
        barrierReceipt receipt: TerminalSurfaceMutationReceipt
    ) {
        self.deliveryID = deliveryID
        self.payload = .barrier
        self.receipts = [receipt]
        self.replacementScope = nil
        self.viewportPolicy = nil
        self.scrollReconciliation = nil
        self.followingScrollRuns = []
        self.scrollbackOffsetFromBottomRows = nil
        self.authoritativeReconstructedRowCount = nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payload == rhs.payload
            && lhs.replacementScope == rhs.replacementScope
            && lhs.viewportPolicy == rhs.viewportPolicy
            && lhs.scrollReconciliation == rhs.scrollReconciliation
            && lhs.followingScrollRuns == rhs.followingScrollRuns
            && lhs.scrollbackOffsetFromBottomRows == rhs.scrollbackOffsetFromBottomRows
            && lhs.authoritativeReconstructedRowCount == rhs.authoritativeReconstructedRowCount
    }

    var renderGridFrame: MobileTerminalRenderGridFrame? {
        guard case .renderGrid(let renderGrid) = payload else { return nil }
        return renderGrid.frame
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let renderGrid):
            renderGrid.bytes
        case .localScroll, .scrollToBottom, .barrier:
            Data()
        }
    }

    var mutation: MobileTerminalSurfaceMutation {
        switch payload {
        case .bytes, .renderGrid:
            .output(MobileTerminalOutputOperation(
                data: bytes,
                viewportPolicy: viewportPolicy,
                scrollbackOffsetFromBottomRows: scrollbackOffsetFromBottomRows,
                authoritativeReconstructedRowCount: authoritativeReconstructedRowCount,
                followingScrollRuns: followingScrollRuns
            ))
        case .localScroll(let runs):
            .localScroll(runs)
        case .scrollToBottom:
            .scrollToBottom
        case .barrier:
            .barrier
        }
    }

    var isInteractionMutation: Bool {
        switch payload {
        case .bytes, .renderGrid:
            false
        case .localScroll, .scrollToBottom, .barrier:
            true
        }
    }

    var nonreplaceableRawByteCount: Int? {
        guard replacementScope == nil, case .bytes(let data) = payload else { return nil }
        return data.count
    }

    var retainedOutputByteCount: Int {
        switch payload {
        case .bytes(let data): data.count
        case .renderGrid(let renderGrid): renderGrid.bytes.count
        case .localScroll, .scrollToBottom, .barrier: 0
        }
    }

    var isRenderGrid: Bool {
        if case .renderGrid = payload { return true }
        return false
    }

    @MainActor
    func resolveReceipt(_ applied: Bool) {
        for receipt in receipts {
            receipt.resolve(applied)
        }
    }

    mutating func mergeLocalScroll(_ newer: Self) -> Bool {
        guard case .localScroll(var combinedRuns) = payload,
              case .localScroll(let newerRuns) = newer.payload else {
            return false
        }
        for run in newerRuns {
            if let lastIndex = combinedRuns.indices.last,
               TerminalScrollRequest.canCoalesce(combinedRuns[lastIndex], run) {
                combinedRuns[lastIndex].merge(run)
            } else {
                guard combinedRuns.count < TerminalScrollRequest.maximumJournalRunCount else {
                    return false
                }
                combinedRuns.append(run)
            }
        }
        payload = .localScroll(combinedRuns)
        return true
    }

    var primaryReceipt: TerminalSurfaceMutationReceipt? {
        receipts.first
    }
}

/// Bounded live render-grid state retained while optimistic scrolling waits for
/// authoritative reconciliation. One self-contained frame may replace earlier
/// deltas; otherwise a replay sentinel avoids both data loss and queue growth.
struct DeferredTerminalRenderGridEvent: Equatable, Sendable {
    private(set) var frame: MobileTerminalRenderGridFrame?
    private(set) var preparedBytes: Data?
    private(set) var requiresReplay: Bool
    private var latestRevision: UInt64?

    init(frame: MobileTerminalRenderGridFrame, preparedBytes: Data? = nil) {
        latestRevision = frame.renderRevision
        if frame.full || frame.isReplaceableViewportPatchForMobileDelivery {
            self.frame = frame
            self.preparedBytes = preparedBytes
            requiresReplay = false
        } else {
            self.frame = nil
            self.preparedBytes = nil
            requiresReplay = true
        }
    }

    mutating func append(_ newer: MobileTerminalRenderGridFrame, preparedBytes: Data? = nil) {
        if let currentRevision = latestRevision,
           let newerRevision = newer.renderRevision,
           currentRevision > newerRevision {
            return
        }
        if let newerRevision = newer.renderRevision {
            latestRevision = max(latestRevision ?? 0, newerRevision)
        }
        if newer.full || newer.isReplaceableViewportPatchForMobileDelivery {
            frame = newer
            self.preparedBytes = preparedBytes
            requiresReplay = false
            return
        }
        frame = nil
        self.preparedBytes = nil
        requiresReplay = true
    }
}
