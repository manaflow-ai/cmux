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
    /// This phone's current base-font capacity, fed from every prepared or
    /// sent viewport report. Nil until the first report.
    private var expectedViewportDimensions: Dimensions?
    /// Frames held per epoch while waiting for the daemon to acknowledge a
    /// renegotiated viewport (see `begin`). Bounded so a lost report can
    /// never freeze the terminal on the last verified pixels: once the
    /// budget is spent, mismatched frames verify normally and render
    /// letterboxed at the user's font.
    private var renegotiationHeldFramesByEpoch: [String: Int] = [:]
    static let maxRenegotiationHeldFramesPerEpoch = 4

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
        if let hold = holdForViewportRenegotiation(frame: frame) {
            return hold
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

    /// Holds a frame sized for a grid that does not match this phone's
    /// capacity when the daemon has not yet acknowledged any viewport report
    /// for the frame's epoch — the shape of a reconnect replay captured
    /// before the phone's post-reconnect capacity report landed. The caller
    /// keeps the last verified pixels visible and (on the first hold)
    /// re-sends the capacity report; the acknowledgement then both ends the
    /// hold and floors stale captures, so the next accepted frame is sized
    /// by the settled negotiation. Nil means the frame proceeds normally.
    ///
    /// Never holds without last verified pixels to show, and never holds
    /// more than ``maxRenegotiationHeldFramesPerEpoch`` frames per epoch: a
    /// genuinely smaller settled grant (another viewer constrains the shared
    /// PTY) then verifies normally and renders letterboxed at the user's
    /// font instead of freezing.
    private func holdForViewportRenegotiation(
        frame: MobileTerminalRenderGridFrame
    ) -> BeginDecision? {
        guard let expected = expectedViewportDimensions,
              visibleSnapshot != nil,
              viewportRenderRevisionFloors[frame.renderEpoch] == nil,
              frame.columns != expected.columns || frame.rows != expected.rows else {
            return nil
        }
        let held = renegotiationHeldFramesByEpoch[frame.renderEpoch] ?? 0
        guard held < Self.maxRenegotiationHeldFramesPerEpoch else { return nil }
        renegotiationHeldFramesByEpoch[frame.renderEpoch] = held + 1
        phase = .recovering
        activeTransaction = nil
        return held == 0 ? .renegotiateViewportAndKeepFrozen : .keepFrozenAndRequestReplay
    }

    /// Records the phone's current base-font capacity so `begin` can
    /// recognize frames sized by stale daemon state. Fed from every prepared
    /// or sent viewport report.
    func updateExpectedViewportDimensions(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        expectedViewportDimensions = Dimensions(columns: columns, rows: rows)
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

    /// Starts a new mounted-output ownership generation.
    ///
    /// Unmount invalidation must reject completions from the retired consumer,
    /// while a later mount must be able to verify its cold full replay. Keep the
    /// transaction counter monotonic across both edges so an old async
    /// completion can never match a transaction created by the new mount.
    func prepareForMount() {
        nextTransactionID &+= 1
        clearPresentationState()
        phase = .ready
    }

    func invalidate() {
        nextTransactionID &+= 1
        clearPresentationState()
        phase = .invalidated
    }

    private func clearPresentationState() {
        activeTransaction = nil
        visibleSnapshot = nil
        activeRenderEpoch = nil
        retiredRenderEpochs.removeAll()
        viewportRenderRevisionFloors.removeAll()
        renegotiationHeldFramesByEpoch.removeAll()
        lastVerifiedRenderRevision = 0
        lastVerifiedStateSeq = 0
    }

    private func isNewerThanPresentationFloor(
        _ frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        guard frame.renderEpoch == activeRenderEpoch else { return false }
        let pendingRevision = activeTransaction?.renderRevision ?? 0
        return frame.renderRevision > max(lastVerifiedRenderRevision, pendingRevision)
    }
}
