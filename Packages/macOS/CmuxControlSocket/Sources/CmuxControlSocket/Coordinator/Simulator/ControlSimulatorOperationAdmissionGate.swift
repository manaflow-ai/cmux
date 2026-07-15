import Foundation

/// Bounds long-lived synchronous Simulator RPC waits on connection threads.
final class ControlSimulatorOperationAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumConcurrentOperations: Int
    private var activeOperations = 0

    init(maximumConcurrentOperations: Int) {
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperations < maximumConcurrentOperations else { return false }
        activeOperations += 1
        return true
    }

    func release() {
        lock.lock()
        activeOperations = max(0, activeOperations - 1)
        lock.unlock()
    }
}
