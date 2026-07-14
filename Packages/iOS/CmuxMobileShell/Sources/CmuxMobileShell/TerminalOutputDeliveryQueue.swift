import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks and interaction ordering are preserved. Consecutive pending
/// render-grid viewport replacements may collapse only within the same scope.
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
        var reconciliationGeneration: UInt64
    }

    private struct ClaimedReplayInteraction: Sendable {
        let delivery: TerminalOutputDelivery
        let streamToken: UUID
        var applied: Bool?
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
    private var claimedReplayInteractions: [ClaimedReplayInteraction] = []
    private var barrierInteractionReleaseRequested = false
    private var rawBacklogOverflowed = false
    private var reconciliationSupersessions: [TerminalScrollReconciliationSupersession] = []
    private var reconciliationInvalidationGeneration: UInt64 = 0

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
        guard retainedReplayInteractionCount < Self.maximumQueuedInteractionCount else {
            delivery.resolveReceipt(false)
            return candidateReceipt
        }
        barrierInteractions.append(delivery)
        return candidateReceipt
    }

    mutating func releaseBarrierInteractions() -> TerminalOutputDelivery? {
        barrierInteractionReleaseRequested = true
        return releaseReplayInteractionsIfReady()
    }

    mutating func completeClaimedReplayInteraction(
        streamToken: UUID,
        applied: Bool
    ) -> TerminalOutputDelivery? {
        guard let index = claimedReplayInteractions.firstIndex(where: {
            $0.streamToken == streamToken && $0.applied == nil
        }) else {
            return nil
        }
        claimedReplayInteractions[index].applied = applied
        return releaseReplayInteractionsIfReady()
    }

    private mutating func releaseReplayInteractionsIfReady() -> TerminalOutputDelivery? {
        guard barrierInteractionReleaseRequested,
              claimedReplayInteractions.allSatisfy({ $0.applied != nil }) else {
            return nil
        }
        for claimed in claimedReplayInteractions {
            claimed.delivery.resolveReceipt(claimed.applied == true)
        }
        claimedReplayInteractions.removeAll(keepingCapacity: true)
        barrierInteractionReleaseRequested = false
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

    /// Inserts local scroll behind every existing mutation in one main-actor
    /// step. Authoritative frames stay ordered ahead of later gesture input.
    mutating func enqueueOptimisticScroll(
        _ delivery: TerminalOutputDelivery
    ) -> OptimisticScrollEnqueueResult {
        precondition(delivery.isInteractionMutation)
        let candidateReceipt = delivery.primaryReceipt!
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
        return OptimisticScrollEnqueueResult(immediate: nil, receipt: effectiveReceipt)
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

    @discardableResult
    mutating func completeClaimedInFlight(applied: Bool) -> Bool {
        guard inFlightClaimed else { return false }
        _ = completeInFlight(applied: applied)
        return true
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
        for claimed in claimedReplayInteractions {
            claimed.delivery.resolveReceipt(false)
        }
        inFlight = nil
        inFlightClaimed = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        queuedInteractionCount = 0
        queuedRawByteCount = 0
        queuedRawDeliveryCount = 0
        barrierInteractions.removeAll(keepingCapacity: false)
        claimedReplayInteractions.removeAll(keepingCapacity: false)
        barrierInteractionReleaseRequested = false
        rawBacklogOverflowed = false
        reconciliationSupersessions.removeAll(keepingCapacity: false)
        reconciliationInvalidationGeneration = 0
    }

    mutating func resetForReplayBarrier(claimedStreamToken: UUID? = nil) {
        var retained: [TerminalOutputDelivery] = []
        if let inFlight, inFlight.isInteractionMutation {
            if inFlightClaimed {
                guard let claimedStreamToken else {
                    preconditionFailure("claimed replay interactions require their original stream token")
                }
                claimedReplayInteractions.append(ClaimedReplayInteraction(
                    delivery: inFlight,
                    streamToken: claimedStreamToken,
                    applied: nil
                ))
            } else {
                retained.append(inFlight)
            }
        }
        for index in pendingHeadIndex..<pending.count {
            let delivery = pending[index].delivery
            if delivery.isInteractionMutation {
                retained.append(delivery)
            }
        }
        retained.append(contentsOf: barrierInteractions)
        precondition(
            retained.count + claimedReplayInteractions.count <= Self.maximumQueuedInteractionCount,
            "replay interaction retention must remain bounded"
        )

        inFlight = nil
        inFlightClaimed = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        queuedInteractionCount = 0
        queuedRawByteCount = 0
        queuedRawDeliveryCount = 0
        barrierInteractions = retained
        barrierInteractionReleaseRequested = false
        rawBacklogOverflowed = false
        reconciliationSupersessions.removeAll(keepingCapacity: false)
        reconciliationInvalidationGeneration = 0
    }

    private var retainedReplayInteractionCount: Int {
        claimedReplayInteractions.count + barrierInteractions.count
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
                reconciliationGeneration: reconciliationInvalidationGeneration
            )
            return false
        } else if mergeLocalScroll,
                  let lastIndex = pending.indices.last,
                  lastIndex >= pendingHeadIndex,
                  pending[lastIndex].delivery.mergeLocalScroll(delivery) {
            return false
        } else {
            pending.append(PendingEntry(
                delivery: delivery,
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
            compactPendingStorageIfNeeded()
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
