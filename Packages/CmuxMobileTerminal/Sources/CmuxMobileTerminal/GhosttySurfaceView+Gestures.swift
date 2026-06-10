#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Touch Gestures (scroll, tap, pinch)
extension GhosttySurfaceView {
    @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            MobileDebugLog.anchormux("scroll.pan state=\(gesture.state.rawValue) ty=\(Int(gesture.translation(in: self).y))")
        }
        // Forward scroll to the MAC's real surface instead of scrolling this
        // display-only mirror. The Mac owns scrollback (normal screen) and the
        // program owns alt-screen scroll (mouse-wheel to the PTY); a single
        // `ghostty_surface_mouse_scroll` on the real surface does the
        // mode-correct thing, and the render-grid (which exports the live
        // viewport, `vp_top`) mirrors the result back. Scrolling the local
        // mirror could never do either: it has no scrollback and no program.
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self)
            // Aim for ~1:1 natural scrolling. Measured: the Mac applies a ~3x
            // line multiplier to the wheel delta, so dividing the finger travel
            // by (cell height in points × 3) makes a swipe move the content
            // roughly its own distance. Falls back to a fixed divisor before the
            // first geometry pass measures the cell.
            let cellHeightPt = cellPixelSize.height / max(preferredScreenScale, 1)
            let divisor = cellHeightPt > 1 ? Double(cellHeightPt) * 3 : 42
            pendingScrollLines += Double(translation.y) / divisor
            pendingScrollCell = scrollCell(at: gesture.location(in: self))
            gesture.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            flushPendingScrollIfNeeded()
        default:
            break
        }
    }

    /// Map a touch point to a grid cell (shared effective grid with the Mac), so
    /// alt-screen mouse-wheel reports at the cell under the finger.
    private func scrollCell(at point: CGPoint) -> (col: Int, row: Int) {
        let scale = max(preferredScreenScale, 1)
        let cellW = max(cellPixelSize.width / scale, 1)
        let cellH = max(cellPixelSize.height / scale, 1)
        let col = max(0, Int((point.x - lastRenderRect.minX) / cellW))
        let row = max(0, Int((point.y - lastRenderRect.minY) / cellH))
        return (col, row)
    }

    func flushPendingScrollIfNeeded() {
        guard pendingScrollLines != 0 else { return }
        let lines = pendingScrollLines
        let cell = pendingScrollCell
        pendingScrollLines = 0
        MobileDebugLog.anchormux("scroll.forward lines=\(String(format: "%.2f", lines)) cell=\(cell.col)x\(cell.row)")
        delegate?.ghosttySurfaceView(self, didScrollLines: lines, atCol: cell.col, row: cell.row)
    }

    /// A tap both raises the software keyboard (so the user can type) and
    /// forwards a left click at the tapped cell to the Mac. The Mac's libghostty
    /// self-gates: TUIs with mouse reporting get the click; a normal screen
    /// treats it as a harmless empty selection, so tapping a shell still just
    /// focuses input.
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let cell = scrollCell(at: gesture.location(in: self))
        delegate?.ghosttySurfaceView(self, didTapAtCol: cell.col, row: cell.row)
        focusInput()
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0
        case .changed:
            let delta = gesture.scale - pinchAccumulatedScale
            if abs(delta) >= 0.15 {
                let direction: TerminalFontZoomDirection = delta > 0 ? .increase : .decrease
                if performFontZoom(direction) {
                    pinchAccumulatedScale = gesture.scale
                }
            }
        case .ended, .cancelled:
            // Final sync to make sure the last font change is applied.
            setNeedsGeometrySync()
        default:
            break
        }
    }

}

#endif
