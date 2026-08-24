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
    /// The scroll-event generation bump happens on the main actor before this
    /// enqueue. Restore claims and user viewport batches share `outputQueue`,
    /// and replay reveal waits can target the exact generation that was pending
    /// when the render update tried to present. Deltas accumulated during an
    /// in-flight batch apply as one follow-up batch; obsolete intermediate
    /// deltas are merged, never replayed. No gate lock spans a Ghostty call,
    /// and scrolling never takes Ghostty locks on the main actor.
    func applyLocalScrollbackScroll(
        lines: Double,
        col: Int,
        row: Int,
        interactionGeneration: UInt64
    ) {
        guard lines != 0 else { return }
        pendingLocalScrollLines += lines
        pendingLocalScrollCell = (col, row)
        pendingLocalScrollInteractionGeneration = max(
            pendingLocalScrollInteractionGeneration ?? 0,
            interactionGeneration
        )
        pumpLocalScrollbackScroll()
    }

    func waitForLocalScrollApplied(upTo generation: UInt64) async -> Bool {
        let applied = viewportRestoreGate.withLock {
            $0.appliedInteractionGeneration >= generation
        }
        guard !applied else { return true }
        // A detached or recovered surface cannot apply the batch. Do not park
        // a continuation that has no producer left to resume it; replay
        // callers use `false` to abandon the viewport restore and request a
        // fresh authoritative frame.
        guard surface != nil,
              pendingLocalScrollLines != 0 || localScrollApplyInFlight else {
            return false
        }
        return await withCheckedContinuation { continuation in
            pendingLocalScrollDrains.append((
                generation: generation,
                continuation: continuation
            ))
            pumpLocalScrollbackScroll()
        }
    }

    private func pumpLocalScrollbackScroll() {
        guard !localScrollApplyInFlight,
              pendingLocalScrollLines != 0,
              let surface else {
            return
        }
        let lines = pendingLocalScrollLines
        let cell = pendingLocalScrollCell
        let interactionGeneration = pendingLocalScrollInteractionGeneration
            ?? viewportRestoreGate.withLock { $0.interactionGeneration }
        pendingLocalScrollLines = 0
        pendingLocalScrollInteractionGeneration = nil
        localScrollApplyInFlight = true
        localScrollApplyInFlightGeneration = interactionGeneration
        let token = makeSurfaceOperationID()
        localScrollApplyStartedAt = CACurrentMediaTime()
        localScrollApplyToken = token
        ensureSurfaceOperationDeadlinePump()
        let displayScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let operation = LocalScrollbackSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration,
            token: token
        )
        let workQueue = outputQueue
        let gate = viewportRestoreGate
        workQueue.async { [weak self] in
            let scale = max(Double(displayScale), 1)
            let size = ghostty_surface_size(operation.surface)
            let cellWidthPt = max(Double(size.cell_width_px) / scale, 1)
            let cellHeightPt = max(Double(size.cell_height_px) / scale, 1)
            let posX = (Double(max(0, cell.col)) + 0.5) * cellWidthPt
            let posY = (Double(max(0, cell.row)) + 0.5) * cellHeightPt
            ghostty_surface_mouse_pos(operation.surface, posX, posY, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_scroll(operation.surface, 0, lines, 0)
            gate.withLock {
                $0.appliedInteractionGeneration = max(
                    $0.appliedInteractionGeneration,
                    interactionGeneration
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.localScrollApplyToken == operation.token else { return }
                self.localScrollApplyInFlight = false
                self.localScrollApplyInFlightGeneration = nil
                self.localScrollApplyStartedAt = nil
                self.localScrollApplyToken = nil
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
                self.pumpLocalScrollbackScroll()
            }
        }
    }

    func completePendingLocalScrollDrains(returning result: Bool? = nil) {
        guard !pendingLocalScrollDrains.isEmpty else { return }
        let appliedGeneration = viewportRestoreGate.withLock {
            $0.appliedInteractionGeneration
        }
        var remaining: [(generation: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
        for pending in pendingLocalScrollDrains {
            if let result {
                pending.continuation.resume(returning: result)
            } else if appliedGeneration >= pending.generation {
                pending.continuation.resume(returning: true)
            } else {
                remaining.append(pending)
            }
        }
        pendingLocalScrollDrains = remaining
    }
}

/// One generation-bound pointer used only on its serial Ghostty surface queue.
private nonisolated struct LocalScrollbackSurfaceOperation: @unchecked Sendable {
    // Safety: the surface stays owned by GhosttySurfaceView, and every C call
    // using this pointer is enqueued on that generation's serial output queue.
    let surface: ghostty_surface_t
    let generation: UInt64
    let token: UInt64
}
#endif
