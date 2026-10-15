import Foundation

/// Continuations waiting for a reply by key, each with a deadline on the
/// injected clock: a reply that never comes (a page that navigated away, a
/// shim that dropped the message, quit before the browser closed) fails its
/// waiter with `timeoutError` instead of hanging the caller.
@MainActor
final class CEFReplyWaiters<Key: Hashable & Sendable, Value: Sendable> {
    private struct Waiter {
        let continuation: CheckedContinuation<Value, any Error>
        let deadline: Task<Void, Never>

        func finish(_ result: Result<Value, any Error>) {
            deadline.cancel()
            continuation.resume(with: result)
        }
    }

    private var waiting: [Key: Waiter] = [:]
    /// Replies that arrived while a `send` was still starting its request:
    /// the other side answers some requests before the call that made them
    /// returns their key.
    private var early: [Key: Result<Value, any Error>] = [:]
    private var starting = 0
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    // A main-actor generic class needs a nonisolated deinit while the package
    // targets macOS 14 (the isolated deinit's back-deploy path crashed the
    // Release inliner in cmux Next).
    #if compiler(>=6.2)
    nonisolated deinit {}
    #endif

    var count: Int { waiting.count }

    /// Starts a request with `start` and suspends until its reply, failing
    /// with `timeoutError` after `timeout`. `start` returns the request's key,
    /// or nil when the request could not be made (`notStarted` is thrown).
    /// A reply that arrives inside `start` (a request answered at once, on
    /// this actor) is returned instead of being dropped as late.
    func send(
        timeout: Duration,
        notStarted: @autoclosure () -> any Error,
        timeoutError: @escaping @Sendable () -> any Error,
        _ start: () -> Key?
    ) async throws -> Value {
        starting += 1
        let key = start()
        starting -= 1
        let answered = key.flatMap { early.removeValue(forKey: $0) }
        // Anything else kept answered a request nobody waits for.
        if starting == 0 { early.removeAll() }
        guard let key else { throw notStarted() }
        if let answered { return try answered.get() }
        return try await reply(for: key, timeout: timeout, timeoutError: timeoutError)
    }

    /// Suspends until `resolve(key, ...)`, failing with `timeoutError` after `timeout`.
    func reply(for key: Key, timeout: Duration, timeoutError: @escaping @Sendable () -> any Error) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let clock = clock
            let deadline = Task { [weak self] in
                // One-shot reply deadline, cancelled when the reply arrives.
                do { try await clock.sleep(for: timeout) } catch { return }
                self?.resolve(key, with: .failure(timeoutError()))
            }
            // Keys are unique per request; a reused one fails the older waiter.
            waiting.updateValue(Waiter(continuation: continuation, deadline: deadline), forKey: key)?
                .finish(.failure(CEFError.browserClosed))
        }
    }

    /// Resumes the waiter for `key`; false when none waits (late or timed
    /// out, or early: kept for the `send` still starting it).
    @discardableResult
    func resolve(_ key: Key, with result: Result<Value, any Error>) -> Bool {
        guard let waiter = waiting.removeValue(forKey: key) else {
            if starting > 0 { early[key] = result }
            return false
        }
        waiter.finish(result)
        return true
    }

    /// Fails every waiter whose key matches.
    func failAll(where matches: (Key) -> Bool, with error: any Error) {
        for key in waiting.keys where matches(key) { resolve(key, with: .failure(error)) }
    }
}
