import CMUXMobileCore

/// Owns the single atomic presentation transaction for one mounted terminal.
@MainActor
final class VerifiedTerminalReplayStateMachine {
    struct Dimensions: Equatable {
        let columns: Int
        let rows: Int
    }

    struct Transaction {
        let id: UInt64
        let renderRevision: UInt64
        let stateSeq: UInt64
        let expected: MobileTerminalRenderGridVisualSnapshot
    }

    enum BeginDecision {
        case apply(Transaction)
        case keepFrozenAndRequestReplay
    }

    enum CompletionDecision: Equatable {
        case reveal
        case keepFrozenAndRequestReplay
        case ignoreStaleCompletion
    }

    private enum Phase: Equatable {
        case ready
        case verifying
        case recovering
        case invalidated
    }

    private var phase = Phase.ready
    private var nextTransactionID: UInt64 = 0
    private var activeTransaction: Transaction?
    private var lastVerifiedRenderRevision: UInt64 = 0
    private var lastVerifiedStateSeq: UInt64 = 0

    private(set) var visibleSnapshot: MobileTerminalRenderGridVisualSnapshot?

    var activeTransactionID: UInt64? {
        activeTransaction?.id
    }

    var targetDimensions: Dimensions? {
        activeTransaction.map {
            Dimensions(columns: $0.expected.columns, rows: $0.expected.rowCount)
        }
    }

    var isFrozen: Bool {
        phase == .verifying || phase == .recovering
    }

    func begin(frame: MobileTerminalRenderGridFrame) -> BeginDecision {
        guard phase != .invalidated else {
            return .keepFrozenAndRequestReplay
        }
        guard isNewerThanPresentationFloor(frame) else {
            phase = .recovering
            activeTransaction = nil
            return .keepFrozenAndRequestReplay
        }

        let expected: MobileTerminalRenderGridVisualSnapshot?
        if frame.full {
            expected = MobileTerminalRenderGridVisualSnapshot(fullFrame: frame)
        } else {
            expected = visibleSnapshot?.applying(frame)
        }
        guard let expected else {
            phase = .recovering
            activeTransaction = nil
            return .keepFrozenAndRequestReplay
        }

        nextTransactionID &+= 1
        let transaction = Transaction(
            id: nextTransactionID,
            renderRevision: frame.renderRevision,
            stateSeq: frame.stateSeq,
            expected: expected
        )
        activeTransaction = transaction
        phase = .verifying
        return .apply(transaction)
    }

    func complete(
        transactionID: UInt64,
        observedFrame: MobileTerminalRenderGridFrame?
    ) -> CompletionDecision {
        guard phase != .invalidated,
              let transaction = activeTransaction,
              transaction.id == transactionID else {
            return .ignoreStaleCompletion
        }
        guard let observedFrame,
              let observed = MobileTerminalRenderGridVisualSnapshot(fullFrame: observedFrame),
              observed == transaction.expected else {
            activeTransaction = nil
            phase = .recovering
            return .keepFrozenAndRequestReplay
        }

        visibleSnapshot = transaction.expected
        lastVerifiedRenderRevision = max(lastVerifiedRenderRevision, transaction.renderRevision)
        lastVerifiedStateSeq = max(lastVerifiedStateSeq, transaction.stateSeq)
        activeTransaction = nil
        phase = .ready
        return .reveal
    }

    func invalidate() {
        nextTransactionID &+= 1
        activeTransaction = nil
        visibleSnapshot = nil
        phase = .invalidated
    }

    private func isNewerThanPresentationFloor(
        _ frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        if frame.renderRevision > 0 {
            let pendingRevision = activeTransaction?.renderRevision ?? 0
            return frame.renderRevision > max(lastVerifiedRenderRevision, pendingRevision)
        }
        guard lastVerifiedRenderRevision == 0,
              activeTransaction?.renderRevision ?? 0 == 0 else {
            return false
        }
        let pendingStateSeq = activeTransaction?.stateSeq ?? 0
        return frame.stateSeq >= max(lastVerifiedStateSeq, pendingStateSeq)
    }
}
