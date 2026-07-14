import Foundation

@MainActor
final class MobileViewportMetricsReapplyState {
    static let maxMetricsFollowUpPasses = 4

    private struct Transaction {
        var callbackGeneration: UInt64
        var remainingFollowUpPasses: Int
    }

    private var nextGeneration: UInt64 = 0
    private var transaction: Transaction?
    private var applyingGeneration: UInt64?

    /// The token attached to cell-metrics callbacks emitted by the current
    /// font application. Every application gets a fresh token, so duplicate or
    /// delayed callbacks from an older pass cannot consume a newer pass.
    var activeTransactionGeneration: UInt64? {
        transaction?.callbackGeneration
    }

    /// Starts an authoritative application or resumes the transaction that
    /// emitted a queued cell-metrics callback.
    func beginViewportLimitApplication(resuming callbackGeneration: UInt64?) -> UInt64? {
        guard applyingGeneration == nil else { return nil }

        if let callbackGeneration {
            guard var transaction,
                  transaction.callbackGeneration == callbackGeneration,
                  transaction.remainingFollowUpPasses > 0 else { return nil }
            transaction.remainingFollowUpPasses -= 1
            let nextCallbackGeneration = makeGeneration()
            transaction.callbackGeneration = nextCallbackGeneration
            self.transaction = transaction
            applyingGeneration = nextCallbackGeneration
            return nextCallbackGeneration
        }

        let generation = makeGeneration()
        transaction = Transaction(
            callbackGeneration: generation,
            remainingFollowUpPasses: Self.maxMetricsFollowUpPasses
        )
        applyingGeneration = generation
        return generation
    }

    func endViewportLimitApplication(
        generation: UInt64,
        expectsCellMetricsCallback: Bool
    ) {
        guard applyingGeneration == generation else { return }
        applyingGeneration = nil
        guard let transaction,
              transaction.callbackGeneration == generation else { return }
        if !expectsCellMetricsCallback || transaction.remainingFollowUpPasses == 0 {
            self.transaction = nil
        }
    }

    func cancel() {
        transaction = nil
        applyingGeneration = nil
    }

    private func makeGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }
}
