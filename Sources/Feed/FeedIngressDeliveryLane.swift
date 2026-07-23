import Foundation

/// Serializes typed Feed work with bounded zero-wait admission and per-key ordering.
///
/// Safety: event closures execute only on `executionQueue`; scheduler state is accessed only
/// while holding `admissionLock`.
final class FeedIngressDeliveryLane: @unchecked Sendable {
    private typealias Delivery = @Sendable () -> Void

    private struct PendingDelivery: Sendable {
        let metadata: FeedIngressDeliveryMetadata
        let isZeroWait: Bool
        let execute: Delivery
    }

    private static let maximumPendingZeroWaitDeliveries = 32
    private static let maximumPendingOrdinaryZeroWaitDeliveries = 24
    private static let maximumPriorityBurst = 8

    private let executionQueue = DispatchQueue(
        label: "cmux.feed.ingressDelivery",
        qos: .userInitiated
    )

    /// Synchronous-admission carve-out: callers must get overload/results inline, so this lock
    /// guards only short counter/queue mutations; it never waits or executes event work.
    private let admissionLock = NSLock()
    private var pendingDeliveries: [PendingDelivery] = []
    private var pendingZeroWaitCount = 0
    private var pendingOrdinaryZeroWaitCount = 0
    private var drainScheduled = false
    private var consecutivePrioritySelections = 0

    /// Runs acknowledged or actionable ingress after its earlier same-key deliveries.
    func perform<Result: Sendable>(
        metadata: FeedIngressDeliveryMetadata,
        _ delivery: @escaping @Sendable () -> Result
    ) -> Result {
        let result = FeedIngressSynchronousResult<Result>()
        let shouldScheduleDrain = append(
            PendingDelivery(
                metadata: metadata,
                isZeroWait: false,
                execute: {
                    result.resolve(delivery())
                }
            )
        )
        scheduleDrainIfNeeded(shouldScheduleDrain)
        return result.wait()
    }

    /// Admits a typed zero-wait delivery when its bounded capacity class has room.
    func enqueueZeroWait(
        metadata: FeedIngressDeliveryMetadata,
        _ delivery: @escaping @Sendable () -> Void
    ) -> Bool {
        admissionLock.lock()
        guard pendingZeroWaitCount < Self.maximumPendingZeroWaitDeliveries else {
            admissionLock.unlock()
            guard metadata.importance == .sessionCritical else { return false }
            // Previously acknowledged zero-wait work cannot be evicted. Critical lifecycle
            // ingress backpressures outside the lock until the ordered lane can deliver it.
            perform(metadata: metadata, delivery)
            return true
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
                metadata: metadata,
                isZeroWait: true,
                execute: delivery
            )
        )
        let shouldScheduleDrain = beginDrainIfNeeded()
        admissionLock.unlock()
        scheduleDrainIfNeeded(shouldScheduleDrain)
        return true
    }

    private func append(_ delivery: PendingDelivery) -> Bool {
        admissionLock.lock()
        pendingDeliveries.append(delivery)
        let shouldScheduleDrain = beginDrainIfNeeded()
        admissionLock.unlock()
        return shouldScheduleDrain
    }

    /// Called only while `admissionLock` is held.
    private func beginDrainIfNeeded() -> Bool {
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    private func scheduleDrainIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        executionQueue.async {
            self.drainNext()
        }
    }

    private func drainNext() {
        admissionLock.lock()
        guard let selection = nextDeliverySelection() else {
            drainScheduled = false
            consecutivePrioritySelections = 0
            admissionLock.unlock()
            return
        }
        let delivery = pendingDeliveries.remove(at: selection.index)
        consecutivePrioritySelections = selection.countsAsPriority
            ? consecutivePrioritySelections + 1
            : 0
        if delivery.isZeroWait {
            pendingZeroWaitCount -= 1
            if delivery.metadata.importance == .ordinary {
                pendingOrdinaryZeroWaitCount -= 1
            }
        }
        admissionLock.unlock()

        delivery.execute()
        executionQueue.async {
            self.drainNext()
        }
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
        return pendingDeliveries[..<index].allSatisfy {
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
