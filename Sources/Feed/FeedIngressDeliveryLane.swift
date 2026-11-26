import Foundation

/// Delivers typed Feed work with bounded zero-wait admission and per-key ordering.
///
/// Safety: event closures execute only on `executionQueue`; disjoint delivery keys may execute
/// concurrently, and scheduler state is accessed only while holding `admissionLock`.
final class FeedIngressDeliveryLane: @unchecked Sendable {
    private typealias Delivery = @Sendable () -> Void

    private struct PendingDelivery: Sendable {
        let synchronousID: UUID?
        let metadata: FeedIngressDeliveryMetadata
        let isZeroWait: Bool
        let execute: Delivery
    }

    private static let maximumPendingZeroWaitDeliveries = 32
    private static let maximumPendingOrdinaryZeroWaitDeliveries = 24
    private static let maximumPendingSynchronousDeliveries = 32
    private static let maximumActiveDeliveries = 4
    private static let maximumPriorityBurst = 8
    private static let sessionCriticalOverflowTimeout: TimeInterval = 3

    private let executionQueue = DispatchQueue(
        label: "cmux.feed.ingressDelivery",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Synchronous-admission carve-out: callers must get overload/results inline, so this lock
    /// guards only short counter/queue/scheduler mutations; it never waits or executes event work.
    private let admissionLock = NSLock()
    private var pendingDeliveries: [PendingDelivery] = []
    private var pendingZeroWaitCount = 0
    private var pendingOrdinaryZeroWaitCount = 0
    private var pendingSynchronousCount = 0
    private var activeDeliveryCount = 0
    private var activeDeliveryKeys: Set<FeedIngressDeliveryKey> = []
    private var drainScheduled = false
    private var consecutivePrioritySelections = 0

    /// Runs acknowledged or actionable ingress after its earlier same-key deliveries.
    ///
    /// The delivery must call ``FeedIngressSynchronousResult/commit(_:)`` only
    /// at its short, non-suspending mutation boundary. The caller is resolved
    /// after the delivery returns so any subsequent publication stays ordered
    /// before acknowledgment in the ordinary case. A stalled publication gets only
    /// the caller's original deadline so the socket worker still returns.
    func perform<Result: Sendable>(
        metadata: FeedIngressDeliveryMetadata,
        timeout: TimeInterval,
        _ delivery: @escaping @Sendable (FeedIngressSynchronousResult<Result>) -> Void
    ) -> Result? {
        precondition(timeout > 0, "Synchronous Feed ingress requires a positive timeout")
        let result = FeedIngressSynchronousResult<Result>()
        let synchronousID = UUID()
        guard let shouldScheduleDrain = appendSynchronous(
            PendingDelivery(
                synchronousID: synchronousID,
                metadata: metadata,
                isZeroWait: false,
                execute: {
                    guard result.begin() else { return }
                    defer { result.complete() }
                    delivery(result)
                }
            )
        ) else {
            return nil
        }
        scheduleDrainIfNeeded(shouldScheduleDrain)
        let value = result.wait(timeout: timeout)
        if value == nil {
            cancelPendingSynchronousDelivery(id: synchronousID)
        }
        return value
    }

    /// Admits a typed zero-wait delivery when its bounded capacity class has room.
    func enqueueZeroWait(
        metadata: FeedIngressDeliveryMetadata,
        _ delivery: @escaping @Sendable (FeedIngressSynchronousResult<Void>?) -> Void
    ) -> Bool {
        admissionLock.lock()
        guard pendingZeroWaitCount < Self.maximumPendingZeroWaitDeliveries else {
            admissionLock.unlock()
            guard metadata.importance == .sessionCritical else { return false }
            // Previously acknowledged zero-wait work cannot be evicted. Critical lifecycle
            // ingress backpressures outside the lock until the ordered lane can deliver it.
            return perform(
                metadata: metadata,
                timeout: Self.sessionCriticalOverflowTimeout,
                delivery
            ) != nil
        }
        if metadata.importance == .ordinary {
            guard pendingOrdinaryZeroWaitCount < Self.maximumPendingOrdinaryZeroWaitDeliveries else {
                admissionLock.unlock()
                return false
            }
            pendingOrdinaryZeroWaitCount += 1
        }
        pendingZeroWaitCount += 1
        pendingDeliveries.append(
            PendingDelivery(
                synchronousID: nil,
                metadata: metadata,
                isZeroWait: true,
                execute: {
                    delivery(nil)
                }
            )
        )
        let shouldScheduleDrain = beginDrainIfNeeded()
        admissionLock.unlock()
        scheduleDrainIfNeeded(shouldScheduleDrain)
        return true
    }

    private func appendSynchronous(_ delivery: PendingDelivery) -> Bool? {
        admissionLock.lock()
        guard pendingSynchronousCount < Self.maximumPendingSynchronousDeliveries else {
            admissionLock.unlock()
            return nil
        }
        pendingSynchronousCount += 1
        pendingDeliveries.append(delivery)
        let shouldScheduleDrain = beginDrainIfNeeded()
        admissionLock.unlock()
        return shouldScheduleDrain
    }

    private func cancelPendingSynchronousDelivery(id: UUID) {
        var shouldScheduleDrain = false
        admissionLock.lock()
        if let index = pendingDeliveries.firstIndex(where: { $0.synchronousID == id }) {
            pendingDeliveries.remove(at: index)
            pendingSynchronousCount -= 1
            shouldScheduleDrain = beginDrainIfNeeded()
        }
        admissionLock.unlock()
        scheduleDrainIfNeeded(shouldScheduleDrain)
    }

    /// Called only while `admissionLock` is held.
    private func beginDrainIfNeeded() -> Bool {
        guard !drainScheduled,
              !pendingDeliveries.isEmpty,
              activeDeliveryCount < Self.maximumActiveDeliveries else {
            return false
        }
        drainScheduled = true
        return true
    }

    private func scheduleDrainIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        executionQueue.async {
            self.drainPendingDeliveries()
        }
    }

    private func drainPendingDeliveries() {
        var deliveriesToStart: [PendingDelivery] = []
        admissionLock.lock()
        drainScheduled = false
        while activeDeliveryCount < Self.maximumActiveDeliveries,
              let selection = nextDeliverySelection() {
            let delivery = pendingDeliveries.remove(at: selection.index)
            consecutivePrioritySelections = selection.countsAsPriority
                ? consecutivePrioritySelections + 1
                : 0
            if delivery.isZeroWait {
                pendingZeroWaitCount -= 1
                if delivery.metadata.importance == .ordinary {
                    pendingOrdinaryZeroWaitCount -= 1
                }
            } else {
                pendingSynchronousCount -= 1
            }
            activeDeliveryCount += 1
            activeDeliveryKeys.formUnion(delivery.metadata.keys)
            deliveriesToStart.append(delivery)
        }
        if pendingDeliveries.isEmpty, activeDeliveryCount == 0 {
            consecutivePrioritySelections = 0
        }
        admissionLock.unlock()

        for delivery in deliveriesToStart {
            executionQueue.async {
                delivery.execute()
                self.deliveryDidComplete(keys: delivery.metadata.keys)
            }
        }
    }

    private func deliveryDidComplete(keys: Set<FeedIngressDeliveryKey>) {
        admissionLock.lock()
        assert(activeDeliveryCount > 0)
        assert(keys.isSubset(of: activeDeliveryKeys))
        activeDeliveryCount -= 1
        activeDeliveryKeys.subtract(keys)
        if pendingDeliveries.isEmpty, activeDeliveryCount == 0 {
            consecutivePrioritySelections = 0
        }
        let shouldScheduleDrain = beginDrainIfNeeded()
        admissionLock.unlock()
        scheduleDrainIfNeeded(shouldScheduleDrain)
    }

    /// Called only while `admissionLock` is held.
    private func nextDeliverySelection() -> (index: Int, countsAsPriority: Bool)? {
        var firstEligibleIndex: Int?
        var firstPriorityIndex: Int?
        for index in pendingDeliveries.indices where isEligible(index) {
            if firstEligibleIndex == nil {
                firstEligibleIndex = index
            }
            if isPrioritySelection(index) {
                firstPriorityIndex = index
                break
            }
        }
        guard let firstEligibleIndex else { return nil }
        if consecutivePrioritySelections < Self.maximumPriorityBurst,
           let firstPriorityIndex {
            return (firstPriorityIndex, true)
        }
        return (firstEligibleIndex, false)
    }

    /// An entry is eligible only after every earlier entry sharing any key.
    private func isEligible(_ index: Int) -> Bool {
        let keys = pendingDeliveries[index].metadata.keys
        return activeDeliveryKeys.isDisjoint(with: keys)
            && pendingDeliveries[..<index].allSatisfy {
                $0.metadata.keys.isDisjoint(with: keys)
            }
    }

    /// Priority includes the same-key dependency chain leading to priority work.
    private func isPrioritySelection(_ index: Int) -> Bool {
        let delivery = pendingDeliveries[index]
        if delivery.metadata.importance.isPriority {
            return true
        }
        return pendingDeliveries[(index + 1)...].contains {
            $0.metadata.importance.isPriority
                && !$0.metadata.keys.isDisjoint(with: delivery.metadata.keys)
        }
    }
}
