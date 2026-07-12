import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

struct TerminalScrollReconciliation: Equatable, Sendable {
    let interactionEpoch: UInt64
    let clientRevision: UInt64
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
        case renderGrid(MobileTerminalRenderGridFrame)
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
    /// An explicit authoritative viewport position. `nil` preserves the local
    /// position; `.some(0)` snaps to the bottom after a full history rebuild.
    var scrollbackOffsetFromBottomRows: Int?

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
        self.scrollbackOffsetFromBottomRows = scrollbackOffsetFromBottomRows.map { max(0, $0) }
    }

    init(
        deliveryID: UUID = UUID(),
        renderGrid frame: MobileTerminalRenderGridFrame,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollReconciliation: TerminalScrollReconciliation? = nil
    ) {
        self.deliveryID = deliveryID
        self.payload = .renderGrid(frame)
        self.receipts = []
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.scrollReconciliation = scrollReconciliation
        self.scrollbackOffsetFromBottomRows = frame.full && frame.activeScreen == .primary
            ? frame.scrollForwardRows
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
        self.scrollbackOffsetFromBottomRows = nil
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
        self.scrollbackOffsetFromBottomRows = nil
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
        self.scrollbackOffsetFromBottomRows = nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payload == rhs.payload
            && lhs.replacementScope == rhs.replacementScope
            && lhs.viewportPolicy == rhs.viewportPolicy
            && lhs.scrollReconciliation == rhs.scrollReconciliation
            && lhs.scrollbackOffsetFromBottomRows == rhs.scrollbackOffsetFromBottomRows
    }

    var isViewportRepaint: Bool {
        replacementScope == .renderGridViewport || replacementScope == .byteViewport
    }

    var isSupersededByOptimisticScroll: Bool {
        isViewportRepaint || scrollReconciliation != nil
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let frame):
            frame.vtPatchBytes()
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
                scrollbackOffsetFromBottomRows: scrollbackOffsetFromBottomRows
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
                combinedRuns[lastIndex].lines += run.lines
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
    private(set) var requiresReplay = false

    init(frame: MobileTerminalRenderGridFrame) {
        self.frame = frame
    }

    mutating func append(_ newer: MobileTerminalRenderGridFrame) {
        guard !requiresReplay, let current = frame else { return }
        if let currentRevision = current.renderRevision,
           let newerRevision = newer.renderRevision,
           currentRevision > newerRevision {
            return
        }
        if newer.full || newer.isReplaceableViewportPatchForMobileDelivery {
            frame = newer
            return
        }
        frame = nil
        requiresReplay = true
    }
}
