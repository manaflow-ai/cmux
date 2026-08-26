import Foundation

// SAFETY: this tiny lock is the synchronous handoff from Darwin notification
// callbacks to MainActor. It protects both coalescing flags as one state.
final class SimulatorFramePublicationWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveryIsScheduled = false
    private var signalArrivedWhileScheduled = false

    func recordSignal() -> Bool {
        lock.withLock {
            guard !deliveryIsScheduled else {
                signalArrivedWhileScheduled = true
                return false
            }
            deliveryIsScheduled = true
            return true
        }
    }

    func deliveryDidFinish() -> Bool {
        lock.withLock {
            guard signalArrivedWhileScheduled else {
                deliveryIsScheduled = false
                return false
            }
            signalArrivedWhileScheduled = false
            return true
        }
    }

    func abandonDelivery() {
        lock.withLock {
            deliveryIsScheduled = false
            signalArrivedWhileScheduled = false
        }
    }
}
