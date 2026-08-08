#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Apply the scroll to the phone's local Ghostty mirror immediately. On the
    /// primary screen this consumes the preloaded local scrollback window, so a
    /// drag/deceleration feels native while the Mac catches up. On alternate
    /// screens libghostty turns this into mouse-wheel bytes; the mirror is
    /// display-only and drops those bytes, so the authoritative Mac response
    /// remains the visible update for TUIs.
    ///
    /// The flush-site generation bump happens on the main actor before this
    /// enqueue. Restore claims and user viewport batches share `outputQueue`, so
    /// FIFO ordering makes a pre-restore gesture visible to the claim and applies
    /// a post-restore gesture afterward. Deltas accumulated during an in-flight
    /// batch apply as one follow-up batch; obsolete intermediate deltas are
    /// merged, never replayed. No gate lock spans a Ghostty call, and scrolling
    /// never takes Ghostty locks on the main actor.
    func applyLocalScrollbackScroll(lines: Double, col: Int, row: Int) {
        guard lines != 0 else { return }
        pendingLocalScrollLines += lines
        pendingLocalScrollCell = (col, row)
        pumpLocalScrollbackScroll()
    }

    private func pumpLocalScrollbackScroll() {
        guard !localScrollApplyInFlight,
              pendingLocalScrollLines != 0,
              let surface else {
            return
        }
        let lines = pendingLocalScrollLines
        let cell = pendingLocalScrollCell
        pendingLocalScrollLines = 0
        let interactionGeneration = viewportRestoreGate.withLock { $0.interactionGeneration }
        localScrollApplyInFlight = true
        let displayScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let operation = LocalScrollbackSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration
        )
        let workQueue = outputQueue
        let gate = viewportRestoreGate
        workQueue.async { [weak self] in
            let size = ghostty_surface_size(operation.surface)
            let scale = max(Double(displayScale), 1)
            let cellWidthPt = max(Double(size.cell_width_px) / scale, 1)
            let cellHeightPt = max(Double(size.cell_height_px) / scale, 1)
            let posX = (Double(max(0, cell.col)) + 0.5) * cellWidthPt
            let posY = (Double(max(0, cell.row)) + 0.5) * cellHeightPt
            ghostty_surface_mouse_pos(operation.surface, posX, posY, GHOSTTY_MODS_NONE)
            let precisePixelDelta = lines * Double(size.cell_height_px)
            ghostty_surface_mouse_scroll(operation.surface, 0, precisePixelDelta, 0b0000_0001)
            gate.withLock {
                $0.appliedInteractionGeneration = max(
                    $0.appliedInteractionGeneration,
                    interactionGeneration
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localScrollApplyInFlight = false
                guard self.surface == operation.surface,
                      self.surfaceGeneration == operation.generation else {
                    return
                }
                self.drawForWakeup()
                self.scheduleVisibleArtifactCountUpdate()
                self.pumpLocalScrollbackScroll()
                if !self.localScrollApplyInFlight {
                    // The in-flight flag deferred idle resync while this batch
                    // applied; a drained pump must run the settle it blocked,
                    // because no further scrollbar action is guaranteed.
                    self.settleBoundedScrollMechanicsIfPossible()
                }
            }
        }
    }
}

/// One generation-bound pointer used only on its serial Ghostty surface queue.
private nonisolated struct LocalScrollbackSurfaceOperation: @unchecked Sendable {
    // Safety: the surface stays owned by GhosttySurfaceView, and every C call
    // using this pointer is enqueued on that generation's serial output queue.
    let surface: ghostty_surface_t
    let generation: UInt64
}
#endif
