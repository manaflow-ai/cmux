import os

/// Lets exactly one of a ping's pong-handler calls resume its continuation.
///
/// URLSession may call `sendPing`'s handler again during teardown, from its
/// delegate queue. The handler is synchronous and must resume inline, so a
/// one-shot flag behind a lock fits; an actor would add an async hop between
/// claiming and resuming.
final class PongOnce: Sendable {
    // lint:allow lock -- synchronous one-shot claim from URLSession callbacks (one-shot resume guard carve-out).
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    /// True for the first caller only.
    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
