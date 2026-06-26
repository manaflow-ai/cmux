import Foundation

/// Thread-safe accumulator passed down to per-agent session-index helpers so they
/// can report failures (e.g. SQL prepare errors when an agent bumps its schema)
/// without requiring the helpers to throw across actor boundaries.
///
/// The session-index search fans out across concurrent per-agent loaders, several
/// of which run synchronous file/SQLite work and cannot `await`. They append
/// human-readable error strings here so the UI can surface why a result list
/// looks short or empty rather than the user thinking nothing matched.
///
/// `@unchecked Sendable` justification: the only mutable state is `messages`,
/// guarded on every access by `lock`, so concurrent `add`/`snapshot` from any
/// isolation domain is data-race free.
public final class ErrorBag: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    /// Creates an empty accumulator.
    public init() {}

    /// Appends one failure message. Safe to call concurrently.
    public func add(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(msg)
    }

    /// Returns a copy of every message accumulated so far. Safe to call concurrently.
    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}
