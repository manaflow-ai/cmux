import os

/// Runs an action once: on `fire()` or when the last reference goes away.
/// Gives an unfolding `AsyncStream` the termination callback a
/// continuation-backed one has.
final class StreamTerminationToken: Sendable {
    // carve-out: one take-and-clear, never held across a suspension.
    private let action: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = OSAllocatedUnfairLock(initialState: action) // carve-out: as declared above
    }

    func fire() {
        let taken = action.withLock { action -> (@Sendable () -> Void)? in
            defer { action = nil }
            return action
        }
        taken?()
    }

    deinit { fire() }
}
