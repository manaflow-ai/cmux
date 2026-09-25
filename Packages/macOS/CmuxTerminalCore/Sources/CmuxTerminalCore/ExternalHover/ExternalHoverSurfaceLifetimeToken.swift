import Foundation

/// Owns one external-hover mailbox for exactly one native surface lifetime.
///
/// The token is deliberately a reference type. Work requests retain it while
/// they are queued or suspended, so a late request observes the same sealed
/// state as the lifecycle callback that retired the native surface. The token
/// lock is also the mailbox lock used by ``ExternalHoverOwnerCoordinator``;
/// sealing and publishing a pending entry therefore cannot be separated by a
/// second lock or an actor hop.
public final class ExternalHoverSurfaceLifetimeToken: @unchecked Sendable {
    public let surfaceID: UUID
    public let runtimeSurfaceGeneration: UInt64

    // This lock guards the token's mailbox and retired bit. It is a short,
    // synchronous compare-and-set boundary shared with the Ghostty setter and
    // callback paths, which cannot suspend or enter an actor.
    let lock = NSLock()
    var mailbox = ExternalHoverMailbox()
    var retired = false

    public init(surfaceID: UUID = UUID(), runtimeSurfaceGeneration: UInt64 = 0) {
        self.surfaceID = surfaceID
        self.runtimeSurfaceGeneration = runtimeSurfaceGeneration
    }

    /// Returns whether this generation can still accept external-hover work.
    public var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    /// Permanently seals this generation and invalidates every queued owner
    /// projection. The caller may invoke this synchronously from any thread.
    @discardableResult
    func retire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return false }
        retired = true
        mailbox.teardown()
        return true
    }
}
