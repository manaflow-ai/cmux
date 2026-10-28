import Foundation

/// An operation-count clock makes deadline tests independent of disk/CPU speed.
final class AdvancingUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func read() -> UInt64 {
        lock.lock()
        defer { value += 1; lock.unlock() }
        return value
    }
}
