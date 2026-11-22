import Foundation

/// Continuations waiting for a reply by key, each with a deadline on the
/// injected clock (architecture.md 5a): a reply that never comes (a page
/// that navigated away, a shim that dropped the message, quit before the
/// browser closed) fails its waiter with `timeoutError` instead of hanging
/// the hover preview, snapshot, or script call that awaited it.
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
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var count: Int { waiting.count }

    /// Suspends until `resolve(key, ...)`, failing with `timeoutError` after `timeout`.
    func reply(for key: Key, timeout: Duration, timeoutError: @escaping @Sendable () -> any Error) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let clock = clock
            let deadline = Task { [weak self] in
                // wakeup-allow: one-shot DevTools reply deadline (5 s), cancelled when the reply arrives
                do { try await clock.sleep(for: timeout) } catch { return }
                self?.resolve(key, with: .failure(timeoutError()))
            }
            // Keys are unique per request; a reused one fails the older waiter.
            waiting.updateValue(Waiter(continuation: continuation, deadline: deadline), forKey: key)?
                .finish(.failure(BrowserTabError.closed))
        }
    }

    /// Resumes the waiter for `key`; false when none waits (late or timed out).
    @discardableResult
    func resolve(_ key: Key, with result: Result<Value, any Error>) -> Bool {
        guard let waiter = waiting.removeValue(forKey: key) else { return false }
        waiter.finish(result)
        return true
    }

    /// Fails every waiter whose key matches.
    func failAll(where matches: (Key) -> Bool, with error: any Error) {
        for key in waiting.keys where matches(key) { resolve(key, with: .failure(error)) }
    }
}
