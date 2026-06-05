import Foundation

// Sendable because every access to `generation` is serialized by `lock`.
final class SessionPersistenceWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    @discardableResult
    func invalidateQueuedWrites() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }
}
