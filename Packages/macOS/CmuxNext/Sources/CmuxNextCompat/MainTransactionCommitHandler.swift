import QuartzCore

/// Main-actor work added as a commit handler of the main thread's current Core Animation transaction:
/// the one main-thread proof of ``CATransaction/addMainCommitHandler(forPhase:_:)``.
nonisolated struct MainTransactionCommitHandler: Sendable {
    private let body: @MainActor () -> Void

    /// Makes a handler that runs `body` on the main actor.
    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    /// Adds the handler with `CATransaction.addCommitHandler(_:forPhase:)`. Main actor only, so it joins
    /// the main thread's transaction.
    @MainActor
    func install(forPhase phase: CATransactionPhase) {
        let body = body
        CATransaction.addCommitHandler({
            // main-proof: a commit handler of the main thread's transaction runs in its commit, on main.
            MainActor.assumeIsolated { body() }
        }, forPhase: phase)
    }
}
