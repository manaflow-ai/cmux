#if canImport(UIKit)
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import UIKit

// MARK: - Scrolling (Stage 1 smooth scroll)
//
// Two scroll modes, gated on the active screen:
//
//  - ALTERNATE screen: forward to the MAC's real surface exactly as before.
//    The program owns alt-screen scroll (mouse-wheel to the PTY) and a single
//    `ghostty_surface_mouse_scroll` on the real surface does the mode-correct
//    thing; the render-grid mirrors the result back. TUIs (vim/less
//    --mouse/htop/lazygit) must keep this path untouched.
//
//  - PRIMARY screen: scroll THIS phone's own libghostty surface over the
//    scrollback it holds locally, with NO per-frame RPC to the Mac. The Mac
//    stays the single source of truth for content; the phone only owns a
//    read-only scroll position into already-received history and snaps back to
//    live when new output arrives (see `processOutput`).
//
// Every gate/latch decision lives in `MobileLocalScrollEngine`
// (CmuxMobileTerminalKit, unit-tested); this file is the UIKit + libghostty
// glue.
extension GhosttySurfaceView {
    @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            MobileDebugLog.anchormux("scroll.pan state=\(gesture.state.rawValue) ty=\(Int(gesture.translation(in: self).y)) alt=\(localScroll.isAlternateScreen)")
        }
        switch gesture.state {
        case .began:
            localScroll.notePanBegan()
        case .changed:
            accumulatePanTranslation(gesture)
        case .ended, .cancelled:
            // The recognizer can carry residual translation since the last
            // `.changed` callback; fold it in so the final chunk of the swipe
            // is not dropped, then flush.
            accumulatePanTranslation(gesture)
            flushPendingScrollIfNeeded()
        default:
            break
        }
    }

    /// Fold the gesture's translation since the last call into the pending
    /// scroll, converted to terminal lines.
    ///
    /// Aim for ~1:1 natural scrolling. Measured: the Mac applies a ~3x line
    /// multiplier to the wheel delta, so dividing the finger travel by (cell
    /// height in points × 3) makes a swipe move the content roughly its own
    /// distance. Falls back to a fixed divisor before the first geometry pass
    /// measures the cell.
    private func accumulatePanTranslation(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        guard translation.y != 0 else { return }
        let cellHeightPt = cellPixelSize.height / max(preferredScreenScale, 1)
        let divisor = cellHeightPt > 1 ? Double(cellHeightPt) * 3 : 42
        pendingScrollLines += Double(translation.y) / divisor
        pendingScrollCell = scrollCell(at: gesture.location(in: self))
        gesture.setTranslation(.zero, in: self)
    }

    /// Map a touch point to a grid cell (shared effective grid with the Mac), so
    /// alt-screen mouse-wheel reports at the cell under the finger.
    func scrollCell(at point: CGPoint) -> (col: Int, row: Int) {
        let scale = max(preferredScreenScale, 1)
        let cellW = max(cellPixelSize.width / scale, 1)
        let cellH = max(cellPixelSize.height / scale, 1)
        let col = max(0, Int((point.x - lastRenderRect.minX) / cellW))
        let row = max(0, Int((point.y - lastRenderRect.minY) / cellH))
        return (col, row)
    }

    /// Flush the coalesced scroll once per display-link frame, routed by the
    /// engine: alt screen (or no metadata yet) forwards to the Mac; primary
    /// scrolls the local surface with no RPC.
    func flushPendingScrollIfNeeded() {
        guard pendingScrollLines != 0 else { return }
        let lines = pendingScrollLines
        let cell = pendingScrollCell
        pendingScrollLines = 0

        switch localScroll.flushRoute {
        case .forwardToMac:
            MobileDebugLog.anchormux("scroll.forward lines=\(String(format: "%.2f", lines)) cell=\(cell.col)x\(cell.row) meta=\(localScroll.hasReceivedFrameMeta)")
            delegate?.ghosttySurfaceView(self, didScrollLines: lines, atCol: cell.col, row: cell.row)
        case .scrollLocally:
            scrollLocalSurface(lines: lines, atCell: cell)
        }
    }

    /// Scroll the phone's own libghostty surface over its locally-held history.
    /// `lines` is signed (positive = scroll up into history, matching the wheel
    /// delta convention `ghostty_surface_mouse_scroll` uses on the Mac). Runs the
    /// surface mutation on `outputQueue` so it serializes with `process_output`
    /// (same internal surface lock; firing it from the main-thread gesture would
    /// race the off-main renderer/IO and can wedge on libghostty's futex).
    private func scrollLocalSurface(lines: Double, atCell cell: (col: Int, row: Int)) {
        guard let surface, !isDismantled else { return }

        let outcome = localScroll.applyLocalScroll(lines: lines)
        MobileDebugLog.anchormux("scroll.local lines=\(String(format: "%.2f", lines)) up=\(String(format: "%.1f", outcome.upRows)) held=\(localScroll.heldScrollbackRows)")

        let scale = max(Double(preferredScreenScale), 1)
        let cellW = Double(cellPixelSize.width) / scale
        let cellH = Double(cellPixelSize.height) / scale
        let posX = (Double(cell.col) + 0.5) * cellW
        let posY = (Double(cell.row) + 0.5) * cellH
        // Capture the surface pointer on the main actor; the off-main block only
        // touches the C pointer (serialized with `process_output` on `outputQueue`)
        // and hops back to main for the redraw flag.
        Self.outputQueue.async {
            ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_scroll(surface, 0, lines, 0)
            DispatchQueue.main.async { [weak self] in
                self?.needsDraw = true
            }
        }

        // Reached (or passed) the top of locally-held history while scrolling
        // up: ask the host for ONE deeper-scrollback fetch (not per-frame). The
        // fetch re-flows a deeper snapshot into the local surface, growing
        // history. The engine dedupes and stops at the fully-loaded ceiling.
        if outcome.requestDeeperFetch {
            delegate?.ghosttySurfaceView(self, didReachLocalHistoryTopWithHeldScrollbackRows: localScroll.heldScrollbackRows)
        }
    }

    /// Record the active screen from the latest applied frame (see
    /// ``MobileLocalScrollEngine/noteActiveScreen(isAlternate:)`` for the full
    /// contract, including why the local offset is NOT zeroed here).
    public func setActiveScreen(isAlternate: Bool) {
        localScroll.noteActiveScreen(isAlternate: isAlternate)
    }

    /// Record how much scrollback the local surface now holds, from a full
    /// primary snapshot (see
    /// ``MobileLocalScrollEngine/noteFullSnapshot(scrollbackRows:)`` for the
    /// fetch-classification and restore-arming contract).
    public func setHeldScrollbackRows(_ rows: Int) {
        localScroll.noteFullSnapshot(scrollbackRows: rows)
    }
}
#endif
