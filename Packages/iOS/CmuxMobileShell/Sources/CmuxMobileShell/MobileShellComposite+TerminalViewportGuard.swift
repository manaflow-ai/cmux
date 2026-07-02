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

    /// Whether a producer grid fits the viewport this phone last reported for
    /// `surfaceID`. Grids are trusted until a first report exists.
    func producerGridFitsReportedViewport(
        columns: Int,
        rows: Int,
        surfaceID: String
    ) -> Bool {
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
    /// was withheld: pace a recovery attempt — re-assert the viewport report so
    /// the Mac re-caps the shared grid, and hold the surface's output behind a
    /// replay barrier until a fitting replay repaints it.
    func holdTerminalOutputForOversizedGrid(
        columns: Int,
        rows: Int,
        surfaceID: String,
        source: String
    ) {
        let now = Date()
        if let lastAttempt = oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID],
           now.timeIntervalSince(lastAttempt) < Self.oversizedTerminalGridRecoveryInterval {
            return
        }
        oversizedTerminalGridRecoveryLastAttemptsBySurfaceID[surfaceID] = now
        let reported = reportedTerminalViewportGridsBySurfaceID[surfaceID]
        MobileDebugLog.anchormux(
            "terminal.output.oversized_grid source=\(source) surface=\(surfaceID) " +
                "frame=\(columns)x\(rows) " +
                "reported=\(reported.map { "\($0.columns)x\($0.rows)" } ?? "nil")"
        )
        if let reported {
            Task { @MainActor [weak self] in
                _ = await self?.updateTerminalViewport(
                    surfaceID: surfaceID,
                    columns: reported.columns,
                    rows: reported.rows
                )
            }
        }
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else { return }
        if terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            // The withheld output must register on the live barrier so an
            // empty or not-delivered replay response preserves/retries the
            // recovery instead of releasing the still-diverged stream.
            recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
            // Leave an in-flight barrier replay alone; otherwise nudge the
            // recovery along.
            guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else { return }
            if terminalReplayFailureRetryExhausted(surfaceID: surfaceID) {
                // The previous barrier exhausted its bounded replay retries
                // while the producer stayed diverged. Restart it (which resets
                // the retry budget) at the recovery pace so convergence keeps
                // being attempted instead of wedging a permanently held stream.
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
            return
        }
        // No barrier yet: install one now, even when an unbarriered replay
        // (e.g. the mount-time cold-attach replay) is in flight —
        // `beginTerminalReplayBarrier` cancels it, and its response would carry
        // the same diverged grid anyway. Without this, live bytes keep flowing
        // under the diverged grid for the whole in-flight window. The withheld
        // frame is recorded after the barrier reset so empty/not-delivered
        // replay responses keep the recovery alive.
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        recordWithheldOutputForReplayBarrier(surfaceID: surfaceID)
        requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
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
                  let replayBarrierToken = self.terminalReplayBarrierTokensBySurfaceID[surfaceID],
                  let retryToken = self.prepareTerminalReplayFailureRetry(
                      surfaceID: surfaceID,
                      replayBarrierToken: replayBarrierToken
                  ) else {
                return
            }
            self.requestTerminalReplay(
                surfaceID: surfaceID,
                replayBarrierToken: retryToken,
                coveredReplayBarrierDroppedOutputCount:
                    self.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
            )
        }
    }

    /// A fitting frame arrived; end any oversized-grid recovery pacing so a
    /// later divergence starts a fresh recovery immediately.
    func clearOversizedTerminalGridRecovery(surfaceID: String) {
        oversizedTerminalGridRecoveryLastAttemptsBySurfaceID.removeValue(forKey: surfaceID)
    }
}
