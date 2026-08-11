/// Serializes scrollbar publication with a viewport-preserving output mutation.
///
/// Ghostty may report transient bottom-follow geometry while it applies VT
/// bytes. A preserving transaction suppresses those provisional callbacks and
/// publishes only the authoritative boundary captured after viewport restore.
nonisolated struct ScrollBoundaryCallbackGate: Sendable {
    private var activeTransactionID: UInt64?

    mutating func begin(transactionID: UInt64) {
        activeTransactionID = transactionID
    }

    mutating func observe(_ boundary: TerminalScrollBoundary) -> TerminalScrollBoundary? {
        guard activeTransactionID == nil else { return nil }
        return boundary
    }

    mutating func commit(
        transactionID: UInt64,
        boundary: TerminalScrollBoundary
    ) -> TerminalScrollBoundary? {
        guard activeTransactionID == transactionID else { return nil }
        activeTransactionID = nil
        return boundary
    }

    mutating func cancel(transactionID: UInt64) {
        guard activeTransactionID == transactionID else { return }
        activeTransactionID = nil
    }
}
