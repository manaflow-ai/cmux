import Foundation

extension SessionIndexStore {
    /// Search scope for the "show more" popover.
    enum SearchScope {
        case agent(SessionAgent)
        /// Filter by absolute cwd; nil/"" = unknown-folder bucket.
        case directory(String?)
    }

    /// What the popover gets back. `errors` is non-empty when one or more
    /// agents failed to read their data source (schema mismatch, file missing,
    /// SQL error). UI should surface them so users see why the list looks
    /// short or empty rather than thinking nothing matched.
    struct SearchOutcome: Sendable {
        var entries: [SessionEntry]
        var errors: [String]
    }

    /// Thread-safe accumulator passed down to per-agent helpers so they can
    /// report failures (e.g. SQL prepare errors when an agent bumps its
    /// schema) without requiring the helpers to throw across actor boundaries.
    final class ErrorBag: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func add(_ msg: String) {
            lock.lock()
            defer { lock.unlock() }
            messages.append(msg)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }

        deinit {
            lock.lock()
            messages.removeAll()
            lock.unlock()
        }
    }

    #if DEBUG
    typealias SearchAgentOverrideForTesting = @Sendable (
        _ needle: String,
        _ agent: SessionAgent,
        _ cwdFilter: String?,
        _ offset: Int,
        _ limit: Int,
        _ errorBag: ErrorBag
    ) async -> [SessionEntry]
    #endif
}
