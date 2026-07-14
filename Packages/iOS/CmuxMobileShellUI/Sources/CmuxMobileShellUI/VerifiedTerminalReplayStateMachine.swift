import CMUXMobileCore

/// Owns the single atomic presentation transaction for one mounted terminal.
@MainActor
final class VerifiedTerminalReplayStateMachine {
    typealias Dimensions = VerifiedTerminalReplayDimensions
    typealias Transaction = VerifiedTerminalReplayTransaction
    typealias BeginDecision = VerifiedTerminalReplayBeginDecision
    typealias CompletionDecision = VerifiedTerminalReplayCompletionDecision
    private typealias Phase = VerifiedTerminalReplayPhase

    private var phase = Phase.ready
    private var nextTransactionID: UInt64 = 0
    private var activeTransaction: Transaction?
    private var activeRenderEpoch: String?
    private var retiredRenderEpochs = Set<String>()
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
        guard !frame.renderEpoch.isEmpty,
              frame.renderRevision > 0 else {
            return rejectFrame()
        }
        guard phase != .recovering || frame.full else {
            return rejectFrame()
        }

        let startsNewEpoch = activeRenderEpoch != frame.renderEpoch
        if startsNewEpoch {
            guard frame.full,
                  !retiredRenderEpochs.contains(frame.renderEpoch) else {
                return rejectFrame()
            }
        } else if !isNewerThanPresentationFloor(frame) {
            return rejectFrame()
        }

        let expected: MobileTerminalRenderGridVisualSnapshot?
        if frame.full {
            expected = MobileTerminalRenderGridVisualSnapshot(fullFrame: frame)
        } else {
            expected = visibleSnapshot?.applying(frame)
        }
        guard let expected else {
            return rejectFrame()
        }

        if startsNewEpoch {
            if let activeRenderEpoch {
                retiredRenderEpochs.insert(activeRenderEpoch)
            }
            activeRenderEpoch = frame.renderEpoch
            lastVerifiedRenderRevision = 0
            lastVerifiedStateSeq = 0
        }

        nextTransactionID &+= 1
        let transaction = Transaction(
            id: nextTransactionID,
            renderEpoch: frame.renderEpoch,
            renderRevision: frame.renderRevision,
            stateSeq: frame.stateSeq,
            expected: expected
        )
        activeTransaction = transaction
        phase = .verifying
        return .apply(transaction)
    }

    private func rejectFrame() -> BeginDecision {
        phase = .recovering
        activeTransaction = nil
        return .keepFrozenAndRequestReplay
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
              observedFrame.renderEpoch == transaction.renderEpoch,
              observedFrame.renderRevision == transaction.renderRevision,
              let observed = MobileTerminalRenderGridVisualSnapshot(fullFrame: observedFrame),
              observed == transaction.expected else {
            activeTransaction = nil
            phase = .recovering
            return .keepFrozenAndRequestReplay
        }

        visibleSnapshot = transaction.expected
        lastVerifiedRenderRevision = transaction.renderRevision
        lastVerifiedStateSeq = transaction.stateSeq
        activeTransaction = nil
        phase = .ready
        return .reveal
    }

    /// Invalidates any in-flight verification and returns an overlay token for
    /// output that verified transport refused before it could form a frame.
    func rejectUnverifiedOutput() -> UInt64 {
        nextTransactionID &+= 1
        activeTransaction = nil
        phase = .recovering
        return nextTransactionID
    }

    func invalidate() {
        nextTransactionID &+= 1
        activeTransaction = nil
        visibleSnapshot = nil
        activeRenderEpoch = nil
        retiredRenderEpochs.removeAll()
        phase = .invalidated
    }

    private func isNewerThanPresentationFloor(
        _ frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        guard frame.renderEpoch == activeRenderEpoch else { return false }
        let pendingRevision = activeTransaction?.renderRevision ?? 0
        return frame.renderRevision > max(lastVerifiedRenderRevision, pendingRevision)
    }
}
