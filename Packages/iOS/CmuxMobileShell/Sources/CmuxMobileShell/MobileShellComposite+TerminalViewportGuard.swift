import CMUXMobileCore
internal import CmuxMobileDiagnostics
import Foundation

// Divergence guard for the mobile terminal mirror (issue #7202).
//
// The Mac authors terminal output for its surface grid, normally capped to
// min(every device's reported viewport, pane size) by
// `mobile.terminal.viewport`. In a multi-pane workspace that cap can go
// missing or stale (pane layout churn, a lost report round-trip), leaving the
// producer grid larger than this phone's. Replayed into the smaller local
// grid, absolute row addressing clamps rows beyond the grid onto the bottom
// row and over-wide rows wrap through autowrap — both splice adjacent rows'
// characters into one rendered row, and deltas never repaint the damage.
//
// Every render-grid frame carries the producer's columns×rows, so the phone
// can detect the divergence at ingest: hold the surface's output behind a
// replay barrier (raw bytes authored for the larger grid garble the same
// way and cannot be partially skipped), re-assert this phone's viewport
// report so the Mac re-caps the shared grid, and let the barrier's bounded
// replay retries repaint from the first fitting frame. The Mac emits a full
// frame on every dimension change, so convergence always ends in a complete
// repaint.

extension MobileShellComposite {
    /// Mirror of the Mac-side clamp in `applyMobileViewportReport`
    /// (TerminalController): reports below these floors are raised before the
    /// Mac caps its surface, so a frame may legitimately exceed a smaller
    /// report without being divergent.
    private static let macMobileViewportColumnsRange = 20...300
    private static let macMobileViewportRowsRange = 5...120
    /// Minimum spacing between recovery attempts for one surface, so a
    /// persistently diverged producer re-asserts at a bounded rate instead of
    /// once per frame.
    static let oversizedTerminalGridRecoveryInterval: TimeInterval = 1.5

    /// Whether `frame`'s producer grid fits the viewport this phone last
    /// reported for `surfaceID`. Frames are trusted until a first report
    /// exists (cold attach paints at the Mac's grid exactly as before).
    func renderGridFrameFitsReportedViewport(
        _ frame: MobileTerminalRenderGridFrame,
        surfaceID: String
    ) -> Bool {
        producerGridFitsReportedViewport(
            columns: frame.columns,
            rows: frame.rows,
            surfaceID: surfaceID
        )
    }

    /// Whether the connected Mac can honor `mobile.terminal.viewport` caps:
    /// it either advertises `terminal.viewport.v1` or has returned an
    /// effective grid on this connection. Without that, the oversized-grid
    /// guard must stay off — withholding output based on a cap the host
    /// cannot apply would freeze the mirror on legacy hosts instead of
    /// (at worst) rendering it the pre-guard way.
    private var hostSupportsTerminalViewportCap: Bool {
        if supportedHostCapabilities.contains(Self.terminalViewportCapability) {
            return true
        }
        guard let remoteClient, let confirmedID = terminalViewportRPCConfirmedClientID else {
            return false
        }
        return ObjectIdentifier(remoteClient) == confirmedID
    }

    /// Whether a producer grid fits the viewport this phone last reported for
    /// `surfaceID`. Grids are trusted until a first report exists, and always
    /// trusted against hosts that cannot honor viewport caps.
    func producerGridFitsReportedViewport(
        columns: Int,
        rows: Int,
        surfaceID: String
    ) -> Bool {
        guard hostSupportsTerminalViewportCap else { return true }
        guard let reported = reportedTerminalViewportGridsBySurfaceID[surfaceID] else {
            return true
        }
        let columnsLimit = min(
            max(reported.columns, Self.macMobileViewportColumnsRange.lowerBound),
            Self.macMobileViewportColumnsRange.upperBound
        )
        let rowsLimit = min(
            max(reported.rows, Self.macMobileViewportRowsRange.lowerBound),
            Self.macMobileViewportRowsRange.upperBound
        )
        return columns <= columnsLimit && rows <= rowsLimit
    }

    /// Record withheld output on the surface's active replay barrier so the
    /// barrier survives not-delivered/empty replay responses (they preserve or
    /// retry only when dropped output is present) and the eventual barrier
    /// clear schedules a follow-up repaint.
    func recordWithheldOutputForReplayBarrier(surfaceID: String) {
        terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] =
            (terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0) &+ 1
    }

    /// Output authored for a producer grid this phone cannot render faithfully
    /// was withheld: hold the surface's output behind a replay barrier until a
    /// fitting replay repaints it, and (paced) re-assert the viewport report so
    /// the Mac re-caps the shared grid.
    ///
    /// Only the spammable recovery actions are paced (the report RPC and
    /// replay restarts/nudges). Barrier installation and withheld-output
    /// recording are never paced: a diverged producer with no active barrier
    /// must hold the stream immediately, or raw bytes splice rows during the
    /// pacing window (e.g. a second divergence right after a replay-driven
    /// convergence, which leaves the pacing timestamp warm).
    func holdTerminalOutputForOversizedGrid(
        columns: Int,
        rows: Int,
        surfaceID: String,
        source: String
    ) {
        let hasSink = terminalByteContinuationsBySurfaceID[surfaceID] != nil
        let now = Date()
        if hasSink, terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil {
            // Install the barrier now, even when an unbarriered replay (e.g.
            // the mount-time cold-attach replay) is in flight —
            // `beginTerminalReplayBarrier` cancels it, and its response would
            // carry the same diverged grid anyway. The withheld frame is
            // recorded after the barrier reset so empty/not-delivered replay
            // responses keep the recovery alive.
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
            oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID] = now
            logOversizedGridHold(columns: columns, rows: rows, surfaceID: surfaceID, source: source)
            reassertReportedViewport(surfaceID: surfaceID)
            return
        }
        if hasSink {
            // The withheld output must register on the live barrier so an
            // empty or not-delivered replay response preserves/retries the
            // recovery instead of releasing the still-diverged stream.
            recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
        }
        if let lastAttempt = oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID],
           now.timeIntervalSince(lastAttempt) < Self.oversizedTerminalGridRecoveryInterval {
            return
        }
        oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID] = now
        logOversizedGridHold(columns: columns, rows: rows, surfaceID: surfaceID, source: source)
        reassertReportedViewport(surfaceID: surfaceID)
        // Leave an in-flight barrier replay alone; otherwise nudge the
        // recovery along.
        guard hasSink, !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else { return }
        if terminalReplayFailureRetryExhausted(surfaceID: surfaceID) {
            // The previous barrier exhausted its bounded replay retries while
            // the producer stayed diverged. Restart it (which resets the retry
            // budget) at the recovery pace so convergence keeps being attempted
            // instead of wedging a permanently held stream.
            let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
            recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
        } else if let existingToken = terminalReplayBarrierTokensBySurfaceID[surfaceID] {
            requestTerminalReplay(
                surfaceID: surfaceID,
                replayBarrierToken: existingToken,
                coveredReplayBarrierDroppedOutputCount:
                    terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
            )
        }
    }

    private func logOversizedGridHold(
        columns: Int,
        rows: Int,
        surfaceID: String,
        source: String
    ) {
        let reported = reportedTerminalViewportGridsBySurfaceID[surfaceID]
        MobileDebugLog.anchormux(
            "terminal.output.oversized_grid source=\(source) surface=\(surfaceID) " +
                "frame=\(columns)x\(rows) " +
                "reported=\(reported.map { "\($0.columns)x\($0.rows)" } ?? "nil")"
        )
    }

    private func reassertReportedViewport(surfaceID: String) {
        guard let reported = reportedTerminalViewportGridsBySurfaceID[surfaceID] else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check at send time: the surface can unmount between the
            // capture and this task running. `unregisterTerminalOutput` clears
            // the Mac-side sticky viewport pin; re-sending the stale report
            // here would re-cap the desktop surface for a phone that already
            // navigated away.
            guard self.terminalByteContinuationsBySurfaceID[surfaceID] != nil,
                  let current = self.reportedTerminalViewportGridsBySurfaceID[surfaceID],
                  current == reported else {
                return
            }
            _ = await self.updateTerminalViewport(
                surfaceID: surfaceID,
                columns: reported.columns,
                rows: reported.rows
            )
            // The surface can also unmount while the report round-trip is in
            // flight, landing our sticky pin after the unregister path's
            // clear. Compensate so a detached phone never keeps the Mac grid
            // capped.
            if self.terminalByteContinuationsBySurfaceID[surfaceID] == nil {
                self.clearTerminalViewport(surfaceID: surfaceID)
            }
        }
    }

    /// A replay response still carries an oversized grid (the Mac has not
    /// re-applied this phone's cap yet). Consume one bounded failure retry so
    /// the barrier keeps polling for the converged grid without looping on
    /// every response forever; once retries exhaust, the paced
    /// ``holdTerminalOutputForOversizedGrid(_:surfaceID:source:)`` restarts
    /// recovery on the next diverged frame.
    func retryTerminalReplayForOversizedGrid(surfaceID: String) {
        // This runs while the rejected replay response's task is still marked
        // in flight for the same barrier token; hop one main-actor turn so its
        // completion bookkeeping lands before the retry is armed.
        Task { @MainActor [weak self] in
            guard let self,
                  let replayBarrierToken = self.terminalReplayBarrierTokensBySurfaceID[surfaceID] else {
                return
            }
            if let retryToken = self.prepareTerminalReplayFailureRetry(
                surfaceID: surfaceID,
                replayBarrierToken: replayBarrierToken
            ) {
                self.requestTerminalReplay(
                    surfaceID: surfaceID,
                    replayBarrierToken: retryToken,
                    coveredReplayBarrierDroppedOutputCount:
                        self.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
                )
                return
            }
            // Retry budget exhausted on diverged responses. If a fitting frame
            // was observed during this recovery, the producer has converged
            // and — on an idle terminal — will never emit another frame to
            // re-arm through `noteFittingRenderGridFrame`. Restart the barrier
            // once (fresh budget) so the converged grid can repaint.
            guard self.oversizedRecoveryObservedFittingFrameSurfaceIDs.remove(surfaceID) != nil,
                  self.terminalByteContinuationsBySurfaceID[surfaceID] != nil,
                  !self.terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
                return
            }
            MobileDebugLog.anchormux("terminal.output.oversized_grid_converged_rearm surface=\(surfaceID)")
            let restartedToken = self.beginTerminalReplayBarrier(surfaceID: surfaceID)
            self.recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
            self.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: restartedToken)
        }
    }

    /// A fitting frame arrived: finish or advance the oversized-grid recovery.
    ///
    /// The recovery marker stays alive for the whole episode — it is only
    /// removed once no barrier is holding the stream (converged and released).
    /// Removing it earlier (e.g. for a fitting frame that arrives while the
    /// barrier replay is still in flight) would discard the one signal that
    /// lets a later fitting frame un-wedge an exhausted barrier, freezing the
    /// stream at the exact moment the Mac converged.
    ///
    /// When every bounded replay retry was spent on still-diverged responses,
    /// the barrier survives (withheld output preserves it) with no replay in
    /// flight, and the drop path refuses to arm one after exhaustion. The
    /// first fitting frame in that state restarts the barrier (resetting the
    /// budget) so the fitting replay repaints and releases it.
    func noteFittingRenderGridFrame(surfaceID: String) {
        guard oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID] != nil else {
            return
        }
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else {
            oversizedTerminalGridRecoveryLastAttemptsBySurfaceID.removeValue(forKey: surfaceID)
            return
        }
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil else {
            // No barrier holds the stream: the recovery episode is over. Drop
            // the pacing marker so a later divergence starts fresh.
            oversizedTerminalGridRecoveryLastAttemptsBySurfaceID.removeValue(forKey: surfaceID)
            oversizedRecoveryObservedFittingFrameSurfaceIDs.remove(surfaceID)
            return
        }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID),
              terminalReplayFailureRetryExhausted(surfaceID: surfaceID) else {
            // A barrier replay is still in flight or has budget left; it will
            // repaint or exhaust on its own. Keep the marker so a later
            // fitting frame can still re-arm after exhaustion — and remember
            // that convergence was observed: an idle terminal emits exactly
            // one dimension-change frame, so if the in-flight chain exhausts
            // on diverged responses this signal re-arms the barrier without
            // needing another frame.
            oversizedRecoveryObservedFittingFrameSurfaceIDs.insert(surfaceID)
            return
        }
        oversizedRecoveryObservedFittingFrameSurfaceIDs.remove(surfaceID)
        MobileDebugLog.anchormux("terminal.output.oversized_grid_converged_rearm surface=\(surfaceID)")
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        // The fitting frame itself is dropped by the restarted barrier below;
        // record it so empty/not-delivered responses keep the recovery alive.
        recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    }
}
