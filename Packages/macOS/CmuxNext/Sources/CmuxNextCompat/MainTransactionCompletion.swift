import QuartzCore

/// Main-actor work set as the current Core Animation transaction's completion: the one
/// main-thread proof of ``CATransaction/setMainCompletion(_:)``.
nonisolated struct MainTransactionCompletion: Sendable {
    private let body: @MainActor () -> Void

    /// Makes a completion that runs `body` on the main actor.
    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    /// Sets the completion with `CATransaction.setCompletionBlock(_:)` on the current transaction.
    func install() {
        let body = body
        CATransaction.setCompletionBlock {
            // main-proof: CATransaction.h: the completion block is called on the main thread.
            MainActor.assumeIsolated { body() }
        }
    }
}
