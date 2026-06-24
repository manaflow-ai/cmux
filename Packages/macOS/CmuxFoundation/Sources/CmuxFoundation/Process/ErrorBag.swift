public import Foundation

/// Thread-safe accumulator of error strings passed down to helpers so they can
/// report failures (e.g. SQL prepare errors when an agent bumps its schema)
/// without requiring the helpers to throw across actor boundaries.
///
/// Deliberately `@unchecked Sendable` rather than an `actor`: callers need a
/// synchronous `add`/`snapshot` contract (they accumulate from non-`async`
/// helpers running on arbitrary threads), so the state is guarded by a small
/// `NSLock` over a `[String]` instead of an actor's `async` boundary.
public final class ErrorBag: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    /// Creates an empty accumulator.
    public init() {}

    /// Appends a failure message. Safe to call concurrently from any thread.
    public func add(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(msg)
    }

    /// Returns a copy of every message accumulated so far.
    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}
