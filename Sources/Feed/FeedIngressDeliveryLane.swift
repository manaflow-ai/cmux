import Foundation

/// Serializes accepted Feed work while bounding best-effort zero-wait admission.
///
/// Safety: event closures execute only on `queue`; the admission fields are accessed only
/// while holding `zeroWaitAdmissionLock`.
final class FeedIngressDeliveryLane: @unchecked Sendable {
    private typealias Delivery = @Sendable () -> Void
    private static let maximumPendingZeroWaitDeliveries = 32

    private let queue = DispatchQueue(
        label: "cmux.feed.ingressDelivery",
        qos: .userInitiated
    )

    /// Narrow synchronous-admission carve-out: this guards only a Boolean and a bounded FIFO;
    /// the critical section never waits, blocks, or executes event work.
    private let zeroWaitAdmissionLock = NSLock()
    private var zeroWaitDeliveryScheduled = false
    private var pendingZeroWaitDeliveries: [Delivery] = []

    /// Runs acknowledged or actionable ingress in order with accepted Feed delivery.
    func perform<Result: Sendable>(
        _ delivery: @Sendable () -> Result
    ) -> Result {
        queue.sync(execute: delivery)
    }

    /// Admits a zero-wait delivery when the bounded pending FIFO has capacity.
    func enqueueZeroWait(_ delivery: @escaping @Sendable () -> Void) -> Bool {
        zeroWaitAdmissionLock.lock()
        if zeroWaitDeliveryScheduled {
            guard pendingZeroWaitDeliveries.count < Self.maximumPendingZeroWaitDeliveries else {
                zeroWaitAdmissionLock.unlock()
                return false
            }
            pendingZeroWaitDeliveries.append(delivery)
            zeroWaitAdmissionLock.unlock()
            return true
        }
        zeroWaitDeliveryScheduled = true
        zeroWaitAdmissionLock.unlock()
        schedule(delivery)
        return true
    }

    private func schedule(_ delivery: @escaping Delivery) {
        queue.async {
            delivery()
            self.scheduleNextZeroWaitDelivery()
        }
    }

    private func scheduleNextZeroWaitDelivery() {
        zeroWaitAdmissionLock.lock()
        let nextDelivery: Delivery?
        if pendingZeroWaitDeliveries.isEmpty {
            nextDelivery = nil
            zeroWaitDeliveryScheduled = false
        } else {
            nextDelivery = pendingZeroWaitDeliveries.removeFirst()
        }
        zeroWaitAdmissionLock.unlock()

        if let nextDelivery {
            schedule(nextDelivery)
        }
    }
}
