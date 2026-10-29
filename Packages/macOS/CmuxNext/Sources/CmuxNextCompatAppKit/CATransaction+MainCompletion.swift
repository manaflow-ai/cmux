public import QuartzCore

extension CATransaction {
    /// Sets the current transaction's completion to main-actor work.
    ///
    /// It replaces a hand-written `CATransaction.setCompletionBlock` whose block asserts the
    /// main actor with `assumeIsolated`: the main-thread proof lives once in the internal seam
    /// adapter `MainTransactionCompletion`, and callers write a plain `@MainActor` closure. It
    /// is `setCompletionBlock(_:)` (CATransaction.h): `body` runs
    /// once, when every animation added to the transaction after this call has finished or
    /// been removed; with no animation, at once when the transaction commits. A completion
    /// set earlier in the same transaction runs at once when this one replaces it.
    ///
    /// ```swift
    /// CATransaction.begin()
    /// CATransaction.setMainCompletion { [weak self] in self?.fadeEnded() }
    /// layer.add(fade, forKey: "opacity")
    /// CATransaction.commit()
    /// ```
    ///
    /// - Parameter body: The main-actor work to run when the transaction completes.
    public static func setMainCompletion(_ body: @escaping @MainActor () -> Void) {
        MainTransactionCompletion(body).install()
    }
}
