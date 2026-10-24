public import Foundation

/// Waits for a paid top-up to land (paid-plan.md section 5): asks the return page to grant the
/// payment's session (so the balance rises before the webhook lands), then reads the balance, until
/// it is above where it was or the deadline passes.
///
/// The balance lives on the cmux cloud API, which has no push channel to this app, so the wait
/// reads it again at `interval`. Each sleep goes through the injected `sleep`, so tests run with no
/// real waiting; cancelling the waiting task ends the wait.
///
/// ```swift
/// let waiter = CloudCreditsWaiter(balance: { try await client.balance().availableUSD },
///                                 grant: { await client.grant(session: $0) })
/// let outcome = try await waiter.wait(above: before, session: "cs_test_…")
/// ```
public nonisolated struct CloudCreditsWaiter: Sendable {
    /// How a wait ended.
    public enum Outcome: Sendable, Equatable {
        /// The balance rose: the credits are usable.
        case rose(availableUSD: Double)
        /// The deadline passed first (the person has not paid, or left the page).
        case timedOut(availableUSD: Double)
    }

    let interval: Duration
    let deadline: Duration
    let balance: @Sendable () async throws -> Double
    let grant: @Sendable (String) async -> Void
    let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - interval: how long between reads (default 1 s: a saved card pays in a few seconds).
    ///   - deadline: how long the wait lasts in all (default 15 minutes, Checkout's own idle limit).
    ///   - balance: reads the credits left to spend, in USD.
    ///   - grant: asks the return page to grant a Checkout session.
    ///   - sleep: waits one interval; the default is `Task.sleep`.
    public init(interval: Duration = .seconds(1), deadline: Duration = .seconds(15 * 60),
                balance: @escaping @Sendable () async throws -> Double,
                grant: @escaping @Sendable (String) async -> Void,
                // A bounded, cancellable delay between reads of a server-side balance (no push channel).
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.interval = interval
        self.deadline = deadline
        self.balance = balance
        self.grant = grant
        self.sleep = sleep
    }

    /// Waits until the balance is above `above`. `session` is the payment's Checkout session, which
    /// each round asks the return page to grant; nil leaves the grant to the webhook.
    /// - Throws: the balance read's error, or `CancellationError` when the task is cancelled.
    public func wait(above: Double, session: String?) async throws -> Outcome {
        var waited: Duration = .zero
        while true {
            try Task.checkCancellation()
            if let session { await grant(session) }
            let available = try await balance()
            if available > above { return .rose(availableUSD: available) }
            if waited >= deadline { return .timedOut(availableUSD: available) }
            try await sleep(interval)
            waited += interval
        }
    }
}
