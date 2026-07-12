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

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks are nonreplaceable barriers. Render-grid chunks that repaint
/// the whole viewport are replaceable while the iOS surface is still applying a
/// prior chunk, so fast scroll gestures can skip obsolete intermediate frames.
@MainActor
struct TerminalOutputDeliveryQueue: Sendable {
    struct OptimisticScrollEnqueueResult {
        let immediate: TerminalOutputDelivery?
        let receipt: TerminalSurfaceMutationReceipt
    }

    private struct PendingEntry: Sendable {
        var delivery: TerminalOutputDelivery
        var optimisticGeneration: UInt64
    }

    private static let maximumQueuedInteractionCount = 64
    private var inFlight: TerminalOutputDelivery?
    private var inFlightClaimed = false
    private var pending: [PendingEntry] = []
    private var pendingHeadIndex = 0
    private var queuedInteractionCount = 0
    private(set) var optimisticInvalidationGeneration: UInt64 = 0
    private(set) var pendingTraversalCount = 0

    var isIdle: Bool {
        inFlight == nil && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    var currentInFlight: TerminalOutputDelivery? {
        inFlight
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> TerminalOutputDelivery? {
        if delivery.isInteractionMutation,
           queuedInteractionCount >= Self.maximumQueuedInteractionCount {
            delivery.resolveReceipt(false)
            return nil
        }
        guard inFlight != nil else {
            if delivery.isInteractionMutation { queuedInteractionCount += 1 }
            inFlight = delivery
            inFlightClaimed = false
            return delivery
        }
        let appended = appendPending(delivery, mergeLocalScroll: false)
        if delivery.isInteractionMutation, appended { queuedInteractionCount += 1 }
        return nil
    }

    /// Invalidates older unclaimed viewport/reconciliation output and inserts
    /// the local scroll behind every preserved mutation in one main-actor step.
    mutating func enqueueOptimisticScroll(
        _ delivery: TerminalOutputDelivery
    ) -> OptimisticScrollEnqueueResult {
        precondition(delivery.isInteractionMutation)
        let candidateReceipt = delivery.primaryReceipt!
        optimisticInvalidationGeneration &+= 1
        let mergesPendingInteraction = canMergePendingTail(with: delivery)
        guard mergesPendingInteraction
                || queuedInteractionCount < Self.maximumQueuedInteractionCount else {
            delivery.resolveReceipt(false)
            return OptimisticScrollEnqueueResult(immediate: nil, receipt: candidateReceipt)
        }
        guard inFlight != nil else {
            queuedInteractionCount += 1
            inFlight = delivery
            inFlightClaimed = false
            return OptimisticScrollEnqueueResult(immediate: delivery, receipt: candidateReceipt)
        }
        let appended = appendPending(delivery, mergeLocalScroll: true)
        if appended { queuedInteractionCount += 1 }
        let effectiveReceipt = appended
            ? candidateReceipt
            : (pending.last?.delivery.primaryReceipt ?? candidateReceipt)
        guard inFlight?.isSupersededByOptimisticScroll == true,
              !inFlightClaimed else {
            return OptimisticScrollEnqueueResult(immediate: nil, receipt: effectiveReceipt)
        }
        inFlight = popPending()
        inFlightClaimed = false
        return OptimisticScrollEnqueueResult(immediate: inFlight, receipt: effectiveReceipt)
    }

    mutating func completeInFlight(applied: Bool = true) -> TerminalOutputDelivery? {
        guard inFlight != nil else {
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return nil
        }
        if let inFlight {
            inFlight.resolveReceipt(applied)
            if inFlight.isInteractionMutation {
                queuedInteractionCount -= 1
            }
        }
        guard let next = popPending() else {
            inFlight = nil
            inFlightClaimed = false
            pending.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            return nil
        }
        inFlight = next
        inFlightClaimed = false
        return next
    }

    mutating func claimInFlight(deliveryID: UUID) -> Bool {
        guard inFlight?.deliveryID == deliveryID, !inFlightClaimed else { return false }
        inFlightClaimed = true
        return true
    }

    mutating func reset() {
        inFlight?.resolveReceipt(false)
        for index in pendingHeadIndex..<pending.count {
            pending[index].delivery.resolveReceipt(false)
        }
        inFlight = nil
        inFlightClaimed = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        queuedInteractionCount = 0
        optimisticInvalidationGeneration = 0
        pendingTraversalCount = 0
    }

    private func canMergePendingTail(with delivery: TerminalOutputDelivery) -> Bool {
        guard let lastIndex = pending.indices.last,
              lastIndex >= pendingHeadIndex else {
            return false
        }
        var tail = pending[lastIndex].delivery
        return tail.mergeLocalScroll(delivery)
    }

    @discardableResult
    private mutating func appendPending(
        _ delivery: TerminalOutputDelivery,
        mergeLocalScroll: Bool
    ) -> Bool {
        if let replacementScope = delivery.replacementScope,
           let lastIndex = pending.indices.last,
           lastIndex >= pendingHeadIndex,
           pending[lastIndex].delivery.replacementScope == replacementScope {
            pending[lastIndex] = PendingEntry(
                delivery: delivery,
                optimisticGeneration: optimisticInvalidationGeneration
            )
            return false
        } else if mergeLocalScroll,
                  let lastIndex = pending.indices.last,
                  lastIndex >= pendingHeadIndex,
                  pending[lastIndex].delivery.mergeLocalScroll(delivery) {
            pending[lastIndex].optimisticGeneration = optimisticInvalidationGeneration
            return false
        } else {
            pending.append(PendingEntry(
                delivery: delivery,
                optimisticGeneration: optimisticInvalidationGeneration
            ))
            return true
        }
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHeadIndex > 32, pendingHeadIndex * 2 >= pending.count else { return }
        pending.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }

    private mutating func popPending() -> TerminalOutputDelivery? {
        while pendingHeadIndex < pending.count {
            let entry = pending[pendingHeadIndex]
            pendingHeadIndex += 1
            pendingTraversalCount += 1
            compactPendingStorageIfNeeded()
            if entry.optimisticGeneration != optimisticInvalidationGeneration,
               entry.delivery.isSupersededByOptimisticScroll {
                continue
            }
            return entry.delivery
        }
        return nil
    }
}
