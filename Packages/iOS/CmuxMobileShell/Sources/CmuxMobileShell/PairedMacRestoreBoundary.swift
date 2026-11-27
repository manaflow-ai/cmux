import Foundation

/// Synchronous restore invalidation token shared by the UI boundary and the
/// backup actor. `signOut()` and team switches are synchronous UI methods, so
/// they need a non-actor way to invalidate restore writes before any async
/// cancellation task gets scheduled.
public final class PairedMacRestoreBoundary: @unchecked Sendable {
    // Justification: this boundary must be synchronously invalidated from
    // sign-out/team-switch UI code before async cleanup tasks are scheduled.
    // Making it an actor would move that ordering behind an `await`.
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Create a restore boundary at generation zero.
    public init() {}

    /// The current restore generation.
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Invalidate every restore that captured an older generation.
    public func invalidate() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    /// Whether a restore that captured `generation` is still allowed to write.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}
