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
    /// The newest report ID recorded by `updateExpectedViewportDimensions`.
    /// Report IDs are minted monotonically by the surface, so an
    /// acknowledgement settles a negotiation only when it answers this exact
    /// report: two reports can carry the SAME dimensions (reassert, retry)
    /// while the daemon's grant differs between them, and an out-of-order
    /// older acknowledgement must not overwrite the newer settlement.
    private var newestViewportReportID: UInt64 = 0
    /// Monotonic token for the machine's negotiation lifetime. Report IDs
    /// are minted by the surface VIEW and restart when a view is recreated,
    /// while this machine survives remounts (`prepareForMount`), so a
    /// delayed acknowledgement from a previous session can alias a fresh
    /// report ID. Every reset advances the generation; an acknowledgement
    /// settles only when it carries the generation its report was recorded
    /// under.
    private var negotiationGeneration: UInt64 = 1
    /// The grid the daemon granted in the acknowledgement that answered the
    /// newest capacity report, and the epoch it was granted for. Frames at
    /// this grid are the settled negotiation even when it differs from the
    /// capacity (another viewer constrains the shared PTY). Single-valued on
    /// purpose: only the newest acknowledgement describes the negotiation,
    /// and scalar state cannot grow across epoch churn. Cleared whenever the
    /// expected capacity changes or the settled epoch retires.
    private var settledViewportGrant: (epoch: String, grant: Dimensions)?
    /// Frames held across ALL epochs while waiting for the daemon to
    /// acknowledge a renegotiated viewport (see `begin`). Bounded so a lost
    /// report — or a producer churning through epochs — can never freeze the
    /// terminal on the last verified pixels: once the budget is spent,
    /// mismatched frames verify normally and render letterboxed at the
    /// user's font. Reset when a negotiation settles or a new one starts, so
    /// each negotiation gets a fresh budget.
    private var renegotiationHeldFrames = 0
    static let maxRenegotiationHeldFrames = 4

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
        // Only frames that survived every staleness filter may renegotiate:
        // a delayed frame from a retired epoch or below the presentation
        // floor is plain-rejected above and must not consume hold budget,
        // invalidate the settlement, or trigger a viewport reassert.
        if let hold = holdForViewportRenegotiation(frame: frame) {
            return hold
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
                // Frames from a retired epoch are rejected outright above,
                // so a settlement for it is dead weight.
                if settledViewportGrant?.epoch == activeRenderEpoch {
                    settledViewportGrant = nil
                }
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

    /// Holds a frame sized by stale daemon state: its grid matches neither
    /// this phone's current capacity nor the grant the daemon acknowledged
    /// for that capacity — the shape of a reconnect replay captured before
    /// the phone's post-reconnect capacity report landed, or of daemon state
    /// that regressed while the phone was detached. The caller keeps the
    /// last verified pixels visible and (on the first hold) re-sends the
    /// capacity report; the acknowledgement then ends the hold, floors stale
    /// captures, and records the settled grant, so the next accepted frame
    /// is sized by the settled negotiation. Nil means the frame proceeds
    /// normally.
    ///
    /// Never holds without last verified pixels to show, and never holds
    /// more than ``maxRenegotiationHeldFrames`` frames per negotiation: if the report is lost, the mismatched frame verifies
    /// normally and renders letterboxed at the user's font instead of
    /// freezing.
    private func holdForViewportRenegotiation(
        frame: MobileTerminalRenderGridFrame
    ) -> BeginDecision? {
        guard let expected = expectedViewportDimensions,
              visibleSnapshot != nil else {
            return nil
        }
        let dims = Dimensions(columns: frame.columns, rows: frame.rows)
        guard dims != expected else { return nil }
        if let settled = settledViewportGrant,
           settled.epoch == frame.renderEpoch,
           settled.grant == dims {
            return nil
        }
        guard renegotiationHeldFrames < Self.maxRenegotiationHeldFrames else { return nil }
        renegotiationHeldFrames += 1
        // A held frame is direct evidence the daemon no longer renders the
        // settled negotiation, so the settlement itself is no longer
        // trustworthy: frames at the superseded grant must renegotiate too,
        // not slide past this gate while the fresh acknowledgement (which
        // alone may restore a settlement) is still in flight.
        settledViewportGrant = nil
        phase = .recovering
        activeTransaction = nil
        return renegotiationHeldFrames == 1
            ? .renegotiateViewportAndKeepFrozen
            : .keepFrozenAndRequestReplay
    }

    /// Records the phone's current base-font capacity so `begin` can
    /// recognize frames sized by stale daemon state. Fed from every prepared
    /// or sent viewport report. A capacity CHANGE starts a new negotiation:
    /// prior settlements and hold budgets no longer describe it. The report
    /// ID always advances, so only the acknowledgement answering the newest
    /// report can settle (see `acknowledgeViewport`).
    ///
    /// - Returns: the negotiation generation this report was recorded under.
    ///   The caller passes it back with the report's acknowledgement so an
    ///   answer from a previous session (before a reset) can never settle
    ///   the current one.
    @discardableResult
    func updateExpectedViewportDimensions(
        columns: Int,
        rows: Int,
        reportID: UInt64
    ) -> UInt64 {
        guard columns > 0, rows > 0 else { return negotiationGeneration }
        newestViewportReportID = max(newestViewportReportID, reportID)
        let dims = Dimensions(columns: columns, rows: rows)
        guard dims != expectedViewportDimensions else { return negotiationGeneration }
        expectedViewportDimensions = dims
        settledViewportGrant = nil
        renegotiationHeldFrames = 0
        return negotiationGeneration
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
    ///
    /// `reportID` identifies the capacity report this acknowledgement
    /// answered (with `reportedColumns`/`reportedRows` as its dimensions,
    /// under `negotiationGeneration` as returned when the report was
    /// recorded) and `grantedColumns`/`grantedRows` the grid the daemon
    /// granted for it. When the answered report belongs to the current
    /// generation, IS the newest recorded report, and its dimensions match
    /// the current expected capacity, the grant is recorded as the settled
    /// negotiation (ending the stale-grid hold) and the hold budget resets.
    /// An out-of-order acknowledgement for an older report or a previous
    /// session still raises the capture floor but settles nothing. Zero
    /// defaults skip settlement entirely and keep floor-only semantics.
    func acknowledgeViewport(
        renderEpoch: String,
        renderRevisionFloor: UInt64,
        reportID: UInt64 = 0,
        negotiationGeneration: UInt64 = 0,
        reportedColumns: Int = 0,
        reportedRows: Int = 0,
        grantedColumns: Int = 0,
        grantedRows: Int = 0
    ) {
        guard !renderEpoch.isEmpty else { return }
        viewportRenderRevisionFloors[renderEpoch] = max(
            viewportRenderRevisionFloors[renderEpoch] ?? 0,
            renderRevisionFloor
        )
        if let expected = expectedViewportDimensions,
           negotiationGeneration == self.negotiationGeneration,
           reportID > 0, reportID >= newestViewportReportID,
           reportedColumns > 0, reportedRows > 0,
           grantedColumns > 0, grantedRows > 0,
           Dimensions(columns: reportedColumns, rows: reportedRows) == expected {
            newestViewportReportID = reportID
            settledViewportGrant = (
                epoch: renderEpoch,
                grant: Dimensions(columns: grantedColumns, rows: grantedRows)
            )
            renegotiationHeldFrames = 0
        }
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
        // Drop the whole negotiation, not just its counters: report IDs
        // restart at zero, so a delayed acknowledgement from the previous
        // session would otherwise compare as "newest" against retained
        // expected dimensions and settle the fresh mount with a stale grant.
        // The new mount learns its capacity from its own first report.
        expectedViewportDimensions = nil
        settledViewportGrant = nil
        renegotiationHeldFrames = 0
        newestViewportReportID = 0
        negotiationGeneration &+= 1
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
