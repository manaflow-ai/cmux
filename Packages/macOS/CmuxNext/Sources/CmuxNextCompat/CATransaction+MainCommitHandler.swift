public import QuartzCore

extension CATransaction {
    /// Runs main-actor work once, at `phase` of the commit of the main thread's current transaction
    /// (`addCommitHandler(_:forPhase:)`, CATransaction.h, macOS 14).
    ///
    /// Unlike a main run-loop observer, the handler joins the transaction that is open now, also from
    /// inside AppKit's display cycle or Core Animation's own commit observer: a `.preCommit` handler
    /// added during the commit's layout or display runs before that same commit, so what it changes
    /// ships with it. With no transaction open it makes the implicit one, committed at the end of the
    /// run-loop turn. The main-thread proof lives once in the seam adapter `MainTransactionCommitHandler`.
    ///
    /// ```swift
    /// CATransaction.addMainCommitHandler(forPhase: .preCommit) { presenter.presentPending() }
    /// ```
    ///
    /// - Parameters:
    ///   - phase: The commit phase that runs `body`.
    ///   - body: The main-actor work.
    @MainActor
    public static func addMainCommitHandler(forPhase phase: CATransactionPhase, _ body: @escaping @MainActor () -> Void) {
        MainTransactionCommitHandler(body).install(forPhase: phase)
    }
}
