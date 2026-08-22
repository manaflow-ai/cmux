#if canImport(UIKit)
import CmuxMobileDiagnostics
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

    func pumpLocalPixelScroll() {
        guard !localPixelScrollApplyInFlight,
              pendingLocalScrollPixels != 0,
              let surface else {
            return
        }
        let deltaPixels = pendingLocalScrollPixels
        let interactionGeneration = pendingLocalPixelScrollInteractionGeneration
            ?? viewportRestoreGate.withLock { $0.interactionGeneration }
        pendingLocalScrollPixels = 0
        pendingLocalPixelScrollInteractionGeneration = nil
        localPixelScrollApplyInFlight = true
        localPixelScrollApplyInFlightGeneration = interactionGeneration
        let token = makeSurfaceOperationID()
        localPixelScrollApplyStartedAt = CACurrentMediaTime()
        localPixelScrollApplyToken = token
        ensureSurfaceOperationDeadlinePump()
        let operation = LocalPixelScrollSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration,
            token: token
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
        pixelState: OSAllocatedUnfairLock<LocalPixelScrollState>
    ) {
        let size = ghostty_surface_size(operation.surface)
        let cellHeightPx = Double(size.cell_height_px)
        guard cellHeightPx >= 1 else {
            pixelState.withLock { $0.remainderPx = 0 }
            return
        }
        var remainder = pixelState.withLock { $0.remainderPx }
        for _ in 0..<2 {
            var scrollbar = ghostty_surface_scrollbar_s()
            guard ghostty_surface_scrollbar(operation.surface, &scrollbar) else { break }
            let total = scrollbar.total
            let len = min(scrollbar.len, total)
            let maxPosition = Double(total - len) * cellHeightPx
            let current = min(Double(scrollbar.offset) * cellHeightPx + remainder, maxPosition)
            let next = min(max(current + deltaPixels, 0), maxPosition)
            var row = UInt64((next / cellHeightPx).rounded(.down))
            var pixelOffset = next - Double(row) * cellHeightPx
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
                let appliedRevision = applied.row_space_revision
                let appliedTotal = applied.total
                pixelState.withLock {
                    $0.remainderPx = appliedOffset
                    #if DEBUG
                    $0.lastApplied = (
                        row: appliedRow,
                        remainderPx: appliedOffset,
                        revision: appliedRevision,
                        total: appliedTotal
                    )
                    #endif
                }
                return
            }
            // Content changed shape mid-batch; rebase once from bottom-of-row.
            remainder = 0
        }
        // Two mismatches in one batch: same units the legacy line path derives
        // from `enqueueScrollMechanicsDelta` (points = px/scale, divisor 3x
        // cell height), so the fallback scrolls the same distance in rows.
        let shouldLog = pixelState.withLock { state -> Bool in
            state.remainderPx = 0
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
}
#endif
