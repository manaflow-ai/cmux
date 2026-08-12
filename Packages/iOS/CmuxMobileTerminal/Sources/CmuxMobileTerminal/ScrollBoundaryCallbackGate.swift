/// Serializes scrollbar publication with a viewport-preserving output mutation.
///
/// Ghostty may report transient bottom-follow geometry while it applies VT
/// bytes. A preserving transaction suppresses those provisional callbacks and
/// publishes only the authoritative boundary captured after viewport restore.
nonisolated struct ScrollBoundaryCallbackGate: Sendable {
    private struct ActiveTransaction: Sendable {
        let id: UInt64
        let interactionGeneration: UInt64
    }

    private var activeTransaction: ActiveTransaction?

    mutating func begin(transactionID: UInt64, interactionGeneration: UInt64) {
        activeTransaction = ActiveTransaction(
            id: transactionID,
            interactionGeneration: interactionGeneration
        )
    }

    mutating func observe(_ boundary: TerminalScrollBoundary) -> TerminalScrollBoundary? {
        guard activeTransaction == nil else { return nil }
        return boundary
    }

    mutating func commit(
        transactionID: UInt64,
        currentInteractionGeneration: UInt64,
        boundary: TerminalScrollBoundary
    ) -> TerminalScrollBoundary? {
        guard let activeTransaction,
              activeTransaction.id == transactionID else { return nil }
        self.activeTransaction = nil
        guard activeTransaction.interactionGeneration == currentInteractionGeneration else {
            return nil
        }
        return boundary
    }

    mutating func cancel(transactionID: UInt64) {
        guard activeTransaction?.id == transactionID else { return }
        activeTransaction = nil
    }
}
