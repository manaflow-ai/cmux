import os

/// Revocable authority carried by detached work across the executor boundary.
///
/// The main-actor owner invalidates the token synchronously when a request is
/// superseded or cancelled. Detached completion checks the same token before
/// hopping to the main actor, so work already known to be obsolete cannot
/// enter apply code. The owner rechecks after the hop to close the race between
/// the off-main check and main-actor execution.
final class DetachedCompletionAuthority: @unchecked Sendable {
    let generation: UInt64

    private let current = OSAllocatedUnfairLock(initialState: true)

    init(generation: UInt64) {
        self.generation = generation
    }

    func invalidate() {
        current.withLock { $0 = false }
    }

    func isCurrent() -> Bool {
        current.withLock { $0 }
    }
}
