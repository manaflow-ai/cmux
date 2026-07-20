import CMUXMobileCore

/// Owns the single atomic presentation transaction for one mounted terminal.
/// "Verified" is deliberately scoped to the producer's serialized cell-grid
/// model plus the exact IOSurface allocation, pixel extent, and Core Animation
/// geometry presented by iOS. It does not claim to independently validate
/// Ghostty's glyph rasterizer or renderer-only image protocols that are absent
/// from the render-grid wire model.
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
    private var viewportRenderRevisionFloors: [String: UInt64] = [:]

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
        if let floor = viewportRenderRevisionFloors[frame.renderEpoch],
           frame.renderRevision <= floor {
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

    /// Orders viewport acknowledgements against frame captures from the same
    /// producer epoch. A capture at or below the returned floor was taken
    /// before the Mac acknowledged the new effective grid.
    func acknowledgeViewport(renderEpoch: String, renderRevisionFloor: UInt64) {
        guard !renderEpoch.isEmpty else { return }
        viewportRenderRevisionFloors[renderEpoch] = max(
            viewportRenderRevisionFloors[renderEpoch] ?? 0,
            renderRevisionFloor
        )
        guard let activeTransaction,
              activeTransaction.renderEpoch == renderEpoch,
              activeTransaction.renderRevision <= renderRevisionFloor else {
            return
        }
        self.activeTransaction = nil
        phase = .recovering
    }

    func invalidate() {
        nextTransactionID &+= 1
        activeTransaction = nil
        visibleSnapshot = nil
        activeRenderEpoch = nil
        retiredRenderEpochs.removeAll()
        viewportRenderRevisionFloors.removeAll()
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
