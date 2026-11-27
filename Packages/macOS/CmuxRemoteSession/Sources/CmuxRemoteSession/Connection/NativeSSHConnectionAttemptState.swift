internal import Foundation

/// Main-actor state for one endpoint's active attempt, cooldown, and FIFO waiters.
struct NativeSSHConnectionAttemptState {
    var activeToken: UUID?
    var waiterOrder: [UUID] = []
    var waiterHeadIndex = 0
    var waiters: [UUID: CheckedContinuation<NativeSSHConnectionPermit, any Error>] = [:]
    var cooldownToken: UUID?
    var cooldownTask: Task<Void, Never>?

    mutating func nextWaiter() -> CheckedContinuation<NativeSSHConnectionPermit, any Error>? {
        while waiterHeadIndex < waiterOrder.count {
            let token = waiterOrder[waiterHeadIndex]
            waiterHeadIndex += 1
            if let continuation = waiters.removeValue(forKey: token) {
                compactWaiterOrderIfNeeded()
                return continuation
            }
        }
        waiterOrder.removeAll(keepingCapacity: true)
        waiterHeadIndex = 0
        return nil
    }

    private mutating func compactWaiterOrderIfNeeded() {
        guard waiterHeadIndex >= 64, waiterHeadIndex * 2 >= waiterOrder.count else { return }
        waiterOrder.removeFirst(waiterHeadIndex)
        waiterHeadIndex = 0
    }
}
