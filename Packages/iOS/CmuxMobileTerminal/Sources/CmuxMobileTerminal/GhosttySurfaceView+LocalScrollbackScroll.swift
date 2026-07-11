#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    private var localScrollbackScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }
        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    func localScrollbackScrollState() -> GhosttySurfaceWorkSnapshot? {
        guard let surface, !isDismantled, !renderPipelineRecoveryPaused else { return nil }
        return GhosttySurfaceWorkSnapshot(
            surface: surface,
            generation: surfaceGeneration,
            scale: Double(max(localScrollbackScreenScale, 1)),
            queue: outputQueue
        )
    }

    func requestDrawAfterLocalScrollbackScroll(generation: UInt64) {
        guard surface != nil,
              surfaceGeneration == generation else {
            return
        }
        drawForWakeup()
    }

    /// Apply the scroll to the phone's local Ghostty mirror before forwarding
    /// the matching batch to the Mac. At most one local operation is queued and
    /// one newer batch is retained, so a stalled surface cannot accumulate and
    /// later replay frame-rate scroll work. On alternate screens libghostty
    /// turns this into mouse-wheel bytes; the mirror is display-only and drops
    /// those bytes, so the authoritative Mac response remains visible for TUIs.
    func applyLocalScrollbackScroll(lines: Double, col: Int, row: Int) {
        guard lines != 0 else { return }
        let request = LocalScrollbackScrollRequest(
            lines: lines,
            col: max(0, col),
            row: max(0, row)
        )
        guard let state = localScrollbackScrollState() else {
            forwardAppliedLocalScrollbackScroll(request)
            localScrollbackScrollQueue.finishDraining()
            return
        }
        guard let immediate = localScrollbackScrollQueue.enqueue(request) else { return }
        enqueueLocalScrollbackScroll(immediate, state: state)
    }

    func suppressOutstandingLocalScrollbackScrollForwarding() {
        localScrollbackScrollQueue.suppressInFlightForwardingAndDiscardPending()
    }

    func waitForLocalScrollbackScrollDrain() async {
        await withCheckedContinuation { continuation in
            localScrollbackScrollQueue.registerDrainWaiter(continuation)
        }
    }

    func takeOutstandingLocalScrollbackScroll() -> LocalScrollbackScrollRequest? {
        localScrollbackScrollStartedAt = nil
        return localScrollbackScrollQueue.takeOutstanding()
    }

    func resetLocalScrollbackScroll() {
        localScrollbackScrollStartedAt = nil
        localScrollbackScrollQueue.reset()
    }

    private func enqueueLocalScrollbackScroll(
        _ request: LocalScrollbackScrollRequest,
        state: GhosttySurfaceWorkSnapshot
    ) {
        localScrollbackScrollStartedAt = CACurrentMediaTime()
        ensureSurfaceOperationDeadlinePump()
        state.queue.async { [weak self] in
            let size = ghostty_surface_size(state.surface)
            let cellWidthPt = max(Double(size.cell_width_px) / state.scale, 1)
            let cellHeightPt = max(Double(size.cell_height_px) / state.scale, 1)
            let posX = (Double(request.col) + 0.5) * cellWidthPt
            let posY = (Double(request.row) + 0.5) * cellHeightPt
            ghostty_surface_mouse_pos(state.surface, posX, posY, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_scroll(state.surface, 0, request.lines, 0)
            Task { @MainActor in
                self?.completeLocalScrollbackScroll(request, generation: state.generation)
            }
        }
    }

    private func completeLocalScrollbackScroll(
        _ request: LocalScrollbackScrollRequest,
        generation: UInt64
    ) {
        guard surfaceGeneration == generation else { return }
        guard let completion = localScrollbackScrollQueue.completeInFlight() else { return }
        localScrollbackScrollStartedAt = nil
        guard surface != nil, !isDismantled else {
            localScrollbackScrollQueue.reset()
            return
        }
        requestDrawAfterLocalScrollbackScroll(generation: generation)
        if completion.shouldForward {
            forwardAppliedLocalScrollbackScroll(request)
        }
        guard let next = completion.next else { return }
        guard let state = localScrollbackScrollState() else {
            if let outstanding = takeOutstandingLocalScrollbackScroll() {
                forwardAppliedLocalScrollbackScroll(outstanding)
            }
            finishLocalScrollbackScrollDrain()
            return
        }
        enqueueLocalScrollbackScroll(next, state: state)
    }

    func finishLocalScrollbackScrollDrain() {
        localScrollbackScrollQueue.finishDraining()
    }

    func forwardAppliedLocalScrollbackScroll(_ request: LocalScrollbackScrollRequest) {
        delegate?.ghosttySurfaceView(
            self,
            didScrollLines: request.lines,
            atCol: request.col,
            row: request.row
        )
    }
}
#endif
