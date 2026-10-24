/// Runs async work and then one follow-up, once: when the work ends or when its limit passes,
/// whichever comes first. The follow-up never waits for a slow work item past the limit, and the
/// work is not cancelled when the limit wins (a write in progress finishes or dies with the process).
///
/// The limit is one ``DemandTimer`` deadline on the injected clock; nothing polls. Use it where an
/// end that must come soon (a forced quit) still gives a short save a chance:
///
/// ```swift
/// BoundedCompletion().run(limit: .milliseconds(100), owner: "quit.forceExit") {
///     await home.flushCacheForQuit()
/// } then: { _ in exit(0) }
/// ```
///
/// Tests pass a manual clock and a `then` that records its argument.
public struct BoundedCompletion: Sendable {
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger

    /// - Parameters:
    ///   - clock: Times the limit; the default is the continuous clock, tests pass a manual one.
    ///   - ledger: Where the limit's fire is counted (the app's ledger by default).
    public init(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.clock = clock
        self.ledger = ledger
    }

    /// Starts `work` now and calls `then` once: with true when `work` ended first, with false when
    /// `limit` passed first.
    ///
    /// - Parameters:
    ///   - limit: The longest `then` waits for `work`.
    ///   - owner: Names the limit's deadline in the wakeup ledger.
    ///   - work: The work to give a chance (it runs in its own task).
    ///   - then: The follow-up; runs on no particular executor.
    public func run(limit: Duration, owner: String, _ work: @escaping @Sendable () async -> Void,
                    then: @escaping @Sendable (_ finished: Bool) -> Void) {
        let outcome = FirstOutcome<Bool>()
        let deadline = DemandTimer(owner: owner, clock: clock, ledger: ledger)
        deadline.schedule(after: limit) { outcome.resolve(false) }
        // task-owner: the work given a chance; never cancelled (the limit only stops the waiting)
        Task {
            await work()
            outcome.resolve(true)
        }
        // task-owner: the one follow-up; it holds the deadline until the outcome is known
        Task {
            let finished = await outcome.value()
            deadline.cancel()
            then(finished)
        }
    }
}
