import Foundation

/// Serializes accepted Feed work while bounding best-effort zero-wait admission.
///
/// Safety: event closures execute only on `queue`; the admission fields are accessed only
/// while holding `zeroWaitAdmissionLock`.
final class FeedIngressDeliveryLane: @unchecked Sendable {
    private typealias Delivery = @Sendable () -> Void

    private let queue = DispatchQueue(
        label: "cmux.feed.ingressDelivery",
        qos: .userInitiated
    )

    /// Narrow synchronous-admission carve-out: this guards only a Boolean and one closure;
    /// the critical section never waits, blocks, or executes event work.
    private let zeroWaitAdmissionLock = NSLock()
    private var zeroWaitDeliveryScheduled = false
    private var coalescedZeroWaitDelivery: Delivery?

    /// Runs acknowledged or actionable ingress in order with accepted Feed delivery.
    func perform<Result: Sendable>(
        _ delivery: @Sendable () -> Result
    ) -> Result {
        queue.sync(execute: delivery)
    }

    /// Retains at most the latest zero-wait delivery while another delivery is scheduled.
    func enqueueLatestZeroWait(_ delivery: @escaping @Sendable () -> Void) {
        zeroWaitAdmissionLock.lock()
        if zeroWaitDeliveryScheduled {
            coalescedZeroWaitDelivery = delivery
            zeroWaitAdmissionLock.unlock()
            return
        }
        zeroWaitDeliveryScheduled = true
        zeroWaitAdmissionLock.unlock()
        schedule(delivery)
    }

    private func schedule(_ delivery: @escaping Delivery) {
        queue.async {
            delivery()
            self.scheduleCoalescedZeroWaitDelivery()
        }
    }

    private func scheduleCoalescedZeroWaitDelivery() {
        zeroWaitAdmissionLock.lock()
        let nextDelivery = coalescedZeroWaitDelivery
        coalescedZeroWaitDelivery = nil
        if nextDelivery == nil {
            zeroWaitDeliveryScheduled = false
        }
        zeroWaitAdmissionLock.unlock()

        if let nextDelivery {
            schedule(nextDelivery)
        }
    }
}
