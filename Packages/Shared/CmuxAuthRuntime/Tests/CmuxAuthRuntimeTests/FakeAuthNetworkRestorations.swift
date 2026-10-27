import Foundation
@testable import CmuxAuthRuntime

/// A network-restoration signal the test fires by hand. Waits end on
/// ``restore()`` or on cancellation of the waiting task.
final class FakeAuthNetworkRestorations: AuthNetworkRestorations, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Waits cancelled before their continuation was stored.
    private var cancelledWaiterIDs: Set<UUID> = []
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRestoration() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelledWaiterIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                let parked = parkWaiters
                parkWaiters = []
                lock.unlock()
                for waiter in parked { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            if waiter == nil { cancelledWaiterIDs.insert(id) }
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Suspends until a task waits for a restoration.
    func waitUntilWaiting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !waiters.isEmpty {
                lock.unlock()
                continuation.resume()
                return
            }
            parkWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Reports the network path back to every waiter.
    func restore() {
        lock.lock()
        let woken = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        for waiter in woken { waiter.resume() }
    }
}
