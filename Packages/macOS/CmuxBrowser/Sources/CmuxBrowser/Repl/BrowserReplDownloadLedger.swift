/// Download outcomes of one REPL session, kept as state so a waiter can
/// never miss a completion that arrives while it is getting ready to wait.
@MainActor
public final class BrowserReplDownloadLedger {
    /// How a download ended: the file's path, or an error.
    public struct Outcome: Equatable, Sendable {
        public let path: String?
        public let error: String?

        public init(path: String?, error: String?) {
            self.path = path
            self.error = error
        }
    }

    private var outcomes: [String: Outcome] = [:]
    private var waiters: [String: [CheckedContinuation<Outcome?, Never>]] = [:]

    /// Test seam: runs after the first lookup misses and before the waiter
    /// is registered, where other main-actor work can run in production.
    var willWait: (@MainActor (String) -> Void)?

    public init() {}

    /// Records that download `id` ended and wakes everyone waiting for it.
    public func finish(id: String, path: String?, error: String?) {
        let outcome = Outcome(path: path, error: error)
        outcomes[id] = outcome
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: outcome) }
    }

    /// The outcome of download `id`, if it has ended.
    public func outcome(of id: String) -> Outcome? {
        outcomes[id]
    }

    /// The outcome of download `id`, waiting until it ends or
    /// ``releaseWaiters()`` gives up on it (then `nil`).
    public func wait(for id: String) async -> Outcome? {
        if let outcome = outcomes[id] { return outcome }
        willWait?(id)
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// Wakes every waiter with `nil`, for a session that ends.
    public func releaseWaiters() {
        let all = waiters
        waiters.removeAll()
        for list in all.values {
            for waiter in list { waiter.resume(returning: nil) }
        }
    }
}
