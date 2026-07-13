import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

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

    enum ScrollReconciliationInvalidationResult {
        case advanced(TerminalOutputDelivery?)
        case claimed
    }

    private struct PendingEntry: Sendable {
        var delivery: TerminalOutputDelivery
        var optimisticGeneration: UInt64
        var reconciliationGeneration: UInt64
    }

    private static let maximumQueuedInteractionCount = 64
    static let maximumQueuedRawByteCount = 1_048_576
    static let maximumQueuedRawDeliveryCount = 129
    private var inFlight: TerminalOutputDelivery?
    private var inFlightClaimed = false
    private var pending: [PendingEntry] = []
    private var pendingHeadIndex = 0
    private var queuedInteractionCount = 0
    private var queuedRawByteCount = 0
    private var queuedRawDeliveryCount = 0
    private var barrierInteractions: [TerminalOutputDelivery] = []
    private var rawBacklogOverflowed = false
    private var reconciliationSupersessions: [TerminalScrollReconciliationSupersession] = []
    private(set) var optimisticInvalidationGeneration: UInt64 = 0
    private var reconciliationInvalidationGeneration: UInt64 = 0
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
        if let byteCount = delivery.nonreplaceableRawByteCount,
           queuedRawDeliveryCount >= Self.maximumQueuedRawDeliveryCount
            || byteCount > Self.maximumQueuedRawByteCount - queuedRawByteCount {
            rawBacklogOverflowed = true
            return nil
        }
        if delivery.isInteractionMutation,
           queuedInteractionCount >= Self.maximumQueuedInteractionCount {
            delivery.resolveReceipt(false)
            return nil
        }
        guard inFlight != nil else {
            if delivery.isInteractionMutation { queuedInteractionCount += 1 }
            accountRawDeliveryAdded(delivery)
            inFlight = delivery
            inFlightClaimed = false
            return delivery
        }
        let appended = appendPending(delivery, mergeLocalScroll: false)
        if delivery.isInteractionMutation, appended { queuedInteractionCount += 1 }
        if appended { accountRawDeliveryAdded(delivery) }
        return nil
    }

    mutating func enqueueBarrierInteraction(
        _ delivery: TerminalOutputDelivery
    ) -> TerminalSurfaceMutationReceipt {
        precondition(delivery.isInteractionMutation)
        let candidateReceipt = delivery.primaryReceipt!
        if var tail = barrierInteractions.last, tail.mergeLocalScroll(delivery) {
            barrierInteractions[barrierInteractions.count - 1] = tail
            return tail.primaryReceipt ?? candidateReceipt
        }
        guard barrierInteractions.count < Self.maximumQueuedInteractionCount else {
            delivery.resolveReceipt(false)
            return candidateReceipt
        }
        barrierInteractions.append(delivery)
        return candidateReceipt
    }

    mutating func releaseBarrierInteractions() -> TerminalOutputDelivery? {
        let retained = barrierInteractions
        barrierInteractions.removeAll(keepingCapacity: true)
        var immediate: TerminalOutputDelivery?
        for delivery in retained {
            let candidate = enqueue(delivery)
            if immediate == nil { immediate = candidate }
        }
        return immediate
    }

    mutating func consumeRawBacklogOverflow() -> Bool {
        defer { rawBacklogOverflowed = false }
        return rawBacklogOverflowed
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
        if let inFlight {
            recordSupersededReconciliation(from: inFlight, reason: .optimisticScroll)
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
            accountRawDeliveryRemoved(inFlight)
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

    mutating func invalidateScrollReconciliations() -> ScrollReconciliationInvalidationResult {
        reconciliationInvalidationGeneration &+= 1
        guard inFlight?.scrollReconciliation != nil else {
            return .advanced(nil)
        }
        guard !inFlightClaimed else { return .claimed }
        if let inFlight {
            recordSupersededReconciliation(from: inFlight, reason: .policyInvalidation)
        }
        inFlight = popPending()
        inFlightClaimed = false
        return .advanced(inFlight)
    }

    mutating func takeScrollReconciliationSupersessions() -> [TerminalScrollReconciliationSupersession] {
        let superseded = reconciliationSupersessions
        reconciliationSupersessions.removeAll(keepingCapacity: true)
        return superseded
    }

    mutating func reset() {
        inFlight?.resolveReceipt(false)
        for index in pendingHeadIndex..<pending.count {
            pending[index].delivery.resolveReceipt(false)
        }
        for delivery in barrierInteractions {
            delivery.resolveReceipt(false)
        }
        inFlight = nil
        inFlightClaimed = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        queuedInteractionCount = 0
        queuedRawByteCount = 0
        queuedRawDeliveryCount = 0
        barrierInteractions.removeAll(keepingCapacity: false)
        rawBacklogOverflowed = false
        reconciliationSupersessions.removeAll(keepingCapacity: false)
        optimisticInvalidationGeneration = 0
        reconciliationInvalidationGeneration = 0
        pendingTraversalCount = 0
    }

    mutating func resetForReplayBarrier() {
        let retained = barrierInteractions
        barrierInteractions.removeAll(keepingCapacity: false)
        reset()
        barrierInteractions = retained
    }

    private mutating func accountRawDeliveryAdded(_ delivery: TerminalOutputDelivery) {
        guard let byteCount = delivery.nonreplaceableRawByteCount else { return }
        queuedRawByteCount += byteCount
        queuedRawDeliveryCount += 1
    }

    private mutating func accountRawDeliveryRemoved(_ delivery: TerminalOutputDelivery) {
        guard let byteCount = delivery.nonreplaceableRawByteCount else { return }
        queuedRawByteCount -= byteCount
        queuedRawDeliveryCount -= 1
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
            if pending[lastIndex].delivery.scrollReconciliation != delivery.scrollReconciliation {
                recordSupersededReconciliation(
                    from: pending[lastIndex].delivery,
                    reason: .replacement
                )
            }
            pending[lastIndex] = PendingEntry(
                delivery: delivery,
                optimisticGeneration: optimisticInvalidationGeneration,
                reconciliationGeneration: reconciliationInvalidationGeneration
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
                optimisticGeneration: optimisticInvalidationGeneration,
                reconciliationGeneration: reconciliationInvalidationGeneration
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
                recordSupersededReconciliation(from: entry.delivery, reason: .optimisticScroll)
                continue
            }
            if entry.reconciliationGeneration != reconciliationInvalidationGeneration,
               entry.delivery.scrollReconciliation != nil {
                recordSupersededReconciliation(from: entry.delivery, reason: .policyInvalidation)
                continue
            }
            return entry.delivery
        }
        return nil
    }

    private mutating func recordSupersededReconciliation(
        from delivery: TerminalOutputDelivery,
        reason: TerminalScrollReconciliationSupersession.Reason
    ) {
        guard let reconciliation = delivery.scrollReconciliation,
              !reconciliationSupersessions.contains(where: { $0.reconciliation == reconciliation }),
              reconciliationSupersessions.count < Self.maximumQueuedInteractionCount else {
            return
        }
        reconciliationSupersessions.append(TerminalScrollReconciliationSupersession(
            reconciliation: reconciliation,
            reason: reason
        ))
    }
}
