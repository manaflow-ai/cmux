#if canImport(UIKit)
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import UIKit
import os

extension GhosttySurfaceView {
    /// Pixel-precise variant of ``applyLocalScrollbackScroll(lines:col:row:interactionGeneration:)``
    /// for screen-anchored primary screens. Instead of quantizing the gesture
    /// to whole rows through `mouse_scroll`, each batch positions the viewport
    /// top at an absolute pixel offset from the top of scrollback:
    /// `row * cell_height_px + remainder`. Ghostty applies the (row, remainder)
    /// pair in one critical section, so every presented frame tracks the finger
    /// 1:1 in device pixels. Batching, generations, drains, and deadlines
    /// mirror the line pump exactly.
    func applyLocalPixelScroll(
        pixels: Double,
        interactionGeneration: UInt64
    ) {
        guard pixels != 0 else { return }
        pendingLocalScrollPixels += pixels
        pendingLocalPixelScrollInteractionGeneration = max(
            pendingLocalPixelScrollInteractionGeneration ?? 0,
            interactionGeneration
        )
        pumpLocalPixelScroll()
    }

    /// Re-asserts the held scroll position after a verified replay completed
    /// mid-gesture. The replay reset the mirror to the bottom and the anchor
    /// restore stands down for user interaction, so without this a stationary
    /// finger would see the reset until the next real delta.
    func reassertLocalPixelScrollPositionAfterReplay() {
        // Pixel scrolling exists only on the confirmed-primary screen. Alt
        // screens replay constantly (every frame is verified), and a stale
        // held anchor from earlier primary scrolling must never drive alt
        // renders, so anything but an active primary-screen gesture clears
        // the pixel state outright.
        guard scrollInteractionActive,
              delegate?.ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(self) == true,
              localPixelScrollState.withLock({ $0.lastApplied }) != nil else {
            localPixelScrollState.withLock {
                $0.epoch &+= 1
                $0.remainderPx = 0
                $0.lastApplied = nil
                $0.topRevealPx = 0
            }
            return
        }
        pendingLocalPixelScrollReassert = true
        pumpLocalPixelScroll()
    }

    func pumpLocalPixelScroll() {
        guard !localPixelScrollApplyInFlight,
              pendingLocalScrollPixels != 0 || pendingLocalPixelScrollReassert,
              let surface else {
            return
        }
        let deltaPixels = pendingLocalScrollPixels
        let interactionGeneration = pendingLocalPixelScrollInteractionGeneration
            ?? viewportRestoreGate.withLock { $0.interactionGeneration }
        pendingLocalScrollPixels = 0
        pendingLocalPixelScrollInteractionGeneration = nil
        pendingLocalPixelScrollReassert = false
        // While the finger (or deceleration) owns the gesture, the pump is
        // the position authority: rebase from the last applied position so a
        // verified-replay bottom reset between batches cannot hijack the
        // gesture. Idle batches keep trusting the live viewport.
        let rebaseFromHeldPosition = scrollInteractionActive
        localPixelScrollApplyInFlight = true
        localPixelScrollApplyInFlightGeneration = interactionGeneration
        let token = makeSurfaceOperationID()
        localPixelScrollApplyStartedAt = CACurrentMediaTime()
        localPixelScrollApplyToken = token
        ensureSurfaceOperationDeadlinePump()
        let operation = LocalPixelScrollSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration,
            token: token,
            pixelStateEpoch: localPixelScrollState.withLock { $0.epoch },
            maxTopRevealPx: hostedScrollTopRevealBudgetPx
        )
        let workQueue = outputQueue
        let gate = viewportRestoreGate
        let pixelState = localPixelScrollState
        #if DEBUG
        let enqueuedAt = CACurrentMediaTime()
        #endif
        workQueue.async { [weak self] in
            #if DEBUG
            let batchStartedAt = CACurrentMediaTime()
            #endif
            Self.applyPixelScrollBatch(
                operation: operation,
                deltaPixels: deltaPixels,
                rebaseFromHeldPosition: rebaseFromHeldPosition,
                pixelState: pixelState
            )
            gate.withLock {
                $0.appliedInteractionGeneration = max(
                    $0.appliedInteractionGeneration,
                    interactionGeneration
                )
            }
            #if DEBUG
            // Perf probe for the scroll-hitch investigation: `wait` is
            // head-of-line blocking on this serial queue (a VT apply or render
            // ahead of us), `apply` is the batch itself, `hop` is the
            // main-actor round-trip that gates the next batch.
            let batchEndedAt = CACurrentMediaTime()
            let waitMs = (batchStartedAt - enqueuedAt) * 1000
            let applyMs = (batchEndedAt - batchStartedAt) * 1000
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                if waitMs > 8 || applyMs > 8 {
                    let hopMs = (CACurrentMediaTime() - batchEndedAt) * 1000
                    let shouldLogPerf = pixelState.withLock { state -> Bool in
                        let now = CACurrentMediaTime()
                        guard now - state.lastPerfLogTime >= 0.25 else { return false }
                        state.lastPerfLogTime = now
                        return true
                    }
                    if shouldLogPerf {
                        MobileDebugLog.anchormux(
                            "perf.pixel_scroll wait_ms=\(Int(waitMs)) apply_ms=\(Int(applyMs)) hop_ms=\(Int(hopMs))"
                        )
                    }
                }
                #endif
                guard self.localPixelScrollApplyToken == operation.token else { return }
                self.localPixelScrollApplyInFlight = false
                self.localPixelScrollApplyInFlightGeneration = nil
                self.localPixelScrollApplyStartedAt = nil
                self.localPixelScrollApplyToken = nil
                guard self.surface == operation.surface,
                      self.surfaceGeneration == operation.generation else {
                    self.completePendingLocalScrollDrains(returning: false)
                    return
                }
                self.enqueueRenderSubmission(
                    GhosttySurfaceView.RenderSubmission(
                        token: operation.token,
                        generation: operation.generation,
                        kind: .localScroll,
                        surface: operation.surface,
                        verifiedReplayRead: nil,
                        presentationRetryCount: 0
                    )
                )
                self.drawForWakeup()
                self.scheduleVisibleArtifactCountUpdate()
                self.completePendingLocalScrollDrains()
                self.pumpLocalPixelScroll()
            }
        }
    }

    /// Applies one pixel batch on the serial surface queue. A row-space
    /// revision mismatch rebases once on a fresh scrollbar with a zeroed
    /// remainder; a second mismatch applies the batch through the legacy line
    /// path so scrolling never dies.
    private nonisolated static func applyPixelScrollBatch(
        operation: LocalPixelScrollSurfaceOperation,
        deltaPixels: Double,
        rebaseFromHeldPosition: Bool,
        pixelState: OSAllocatedUnfairLock<LocalPixelScrollState>
    ) {
        let size = ghostty_surface_size(operation.surface)
        let cellHeightPx = Double(size.cell_height_px)
        guard cellHeightPx >= 1 else {
            pixelState.withLock {
                guard $0.epoch == operation.pixelStateEpoch else { return }
                $0.remainderPx = 0
            }
            return
        }
        var (remainder, held, reveal) = pixelState.withLock {
            ($0.remainderPx, $0.lastApplied, $0.topRevealPx)
        }
        for _ in 0..<2 {
            var scrollbar = ghostty_surface_scrollbar_s()
            guard ghostty_surface_scrollbar(operation.surface, &scrollbar) else { break }
            let total = scrollbar.total
            let len = min(scrollbar.len, total)
            let maxPosition = Double(total - len) * cellHeightPx
            // Mid-gesture the held position is the authority: a verified
            // replay may have reset the live viewport to the bottom between
            // batches, and deriving from it would make the reset hijack the
            // gesture. The exact (unrounded) position carries sub-pixel
            // deltas across batches, and the anchor is only trusted while
            // its row space is unchanged: replays repaint in place and keep
            // the revision, while eviction or reflow renumber rows, so a
            // revision change falls back to the live viewport.
            let current: Double
            if rebaseFromHeldPosition, let held,
               held.revision == scrollbar.row_space_revision {
                current = min(held.positionPx, maxPosition)
            } else {
                current = min(Double(scrollbar.offset) * cellHeightPx + remainder, maxPosition)
            }
            // The axis continues past scrollback-top into the top-reveal
            // zone (the keyboard-up presentation's clipped top), so the
            // oldest rows stay reachable while the keyboard is up. The grid
            // gets the non-negative side; the host's content cap follows the
            // reveal side on its display link.
            let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
                currentPositionPx: current,
                currentRevealPx: reveal,
                deltaPixels: deltaPixels,
                maxPositionPx: maxPosition,
                maxRevealPx: operation.maxTopRevealPx
            )
            let next = resolved.positionPx
            var row = UInt64((next / cellHeightPx).rounded(.down))
            // Ghostty gets whole device pixels: a fractional-pixel offset
            // makes glyph antialiasing resample every frame (shimmer);
            // native scrollers always move content by integral pixels.
            var pixelOffset = (next - Double(row) * cellHeightPx).rounded()
            if pixelOffset >= cellHeightPx {
                row += 1
                pixelOffset = 0
            }
            if next >= maxPosition - 0.5 {
                // Docked at the tail: target the absolute bottom and let
                // Ghostty clamp the row into the active area.
                row = total
                pixelOffset = 0
            }
            var applied = ghostty_surface_scrollbar_s()
            if ghostty_surface_scroll_to_row_pixel_if_revision(
                operation.surface,
                row,
                Float(pixelOffset),
                scrollbar.row_space_revision,
                &applied
            ) {
                let appliedRow = row
                let appliedOffset = pixelOffset
                let appliedPosition = next
                let appliedReveal = resolved.revealPx
                let appliedRevision = applied.row_space_revision
                let appliedTotal = applied.total
                pixelState.withLock {
                    // A snap or surface replacement bumped the epoch while
                    // this batch was in flight; its result must not
                    // resurrect the cleared scroll authority.
                    guard $0.epoch == operation.pixelStateEpoch else { return }
                    $0.remainderPx = appliedOffset
                    $0.topRevealPx = appliedReveal
                    $0.lastApplied = (
                        row: appliedRow,
                        remainderPx: appliedOffset,
                        positionPx: appliedPosition,
                        revision: appliedRevision,
                        total: appliedTotal
                    )
                }
                return
            }
            // Content changed shape mid-batch; rebase once from the live
            // viewport with a zeroed remainder (held row numbers are no
            // longer trustworthy in the new row space). The reveal survives:
            // it is presentation-space, not row-space, so a reflow does not
            // invalidate how far the render has slid.
            remainder = 0
            held = nil
        }
        // Two mismatches in one batch: same units the legacy line path derives
        // from `enqueueScrollMechanicsDelta` (points = px/scale, divisor 3x
        // cell height), so the fallback scrolls the same distance in rows.
        let shouldLog = pixelState.withLock { state -> Bool in
            if state.epoch == operation.pixelStateEpoch {
                state.remainderPx = 0
                state.lastApplied = nil
                state.topRevealPx = 0
            }
            let now = CACurrentMediaTime()
            guard now - state.lastFallbackLogTime >= 1 else { return false }
            state.lastFallbackLogTime = now
            return true
        }
        if shouldLog {
            MobileDebugLog.anchormux(
                "local_pixel_scroll.fallback_lines deltaPx=\(Int(deltaPixels))"
            )
        }
        ghostty_surface_mouse_scroll(
            operation.surface,
            0,
            -deltaPixels / (cellHeightPx * 3),
            0
        )
    }
}

/// One generation-bound pointer used only on its serial Ghostty surface queue.
private nonisolated struct LocalPixelScrollSurfaceOperation: @unchecked Sendable {
    // Safety: the surface stays owned by GhosttySurfaceView, and every C call
    // using this pointer is enqueued on that generation's serial output queue.
    let surface: ghostty_surface_t
    let generation: UInt64
    let token: UInt64
    /// Pixel-state epoch captured at pump time; the batch only commits its
    /// results while the state still carries this epoch.
    let pixelStateEpoch: UInt64
    /// The scroll-top reveal budget in device pixels, captured on the main
    /// actor at pump time: how much of the render the keyboard-up bottom-pin
    /// clips above the screen (0 with the keyboard down).
    let maxTopRevealPx: Double
}
#endif
