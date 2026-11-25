#if os(iOS)
import CmuxMobileLinkFFI
import UIKit

// MARK: The alternate screen at the Mac's grid, zoomed (TerminalTUIZoom)

/// A full-screen app whose grid is not the phone's (the projection keeps the
/// Mac's: `TerminalProjectingSession`) is shown at that grid, scaled: the
/// surface keeps the Mac's columns at the reader's font size and takes the
/// zoom as a transform, panned by one finger. Kept out of the controller's
/// body (a god file): the body calls these from its placement, its gestures
/// and its TUI switch.
extension TerminalViewController {
    /// The zoom applies: a full-screen app in the TUI host whose grid is not the phone's,
    /// with Settings → Terminal → Zoom Full-Screen Apps on (``tuiZoomEnabled``).
    var tuiZoomActive: Bool {
        tuiZoomEnabled && model.isTUI && surface.superview === tuiHost && cell.width > 0 && cell.height > 0 && hostLayout.followsHost
    }

    /// The Mac's grid and the TUI area, at scale 1.
    var tuiZoomGeometry: TerminalZoomGeometry? {
        let layout = hostLayout
        guard cell.width > 0, cell.height > 0, tuiRows > 0, let rows = layout.hostRows, rows > 0 else { return nil }
        return TerminalZoomGeometry(gridWidth: Double(CGFloat(layout.columns) * cell.width), gridHeight: Double(CGFloat(rows) * cell.height),
                                    pageWidth: Double(layout.viewportWidth), pageHeight: Double(CGFloat(tuiRows) * cell.height))
    }

    func installTUIZoom() {
        tuiZoom.isActive = { [weak self] in self?.tuiZoomActive ?? false }
        tuiZoom.geometry = { [weak self] in self?.tuiZoomGeometry }
        tuiZoom.columns = { [weak self] in self?.hostLayout.columns ?? 0 }
        tuiZoom.apply = { [weak self] in
            self?.applyTUIPlacement()
            self?.applyHostGridNote()
        }
        tuiZoom.zoomed = { [weak self] in self?.model.zoomGestures += 1 }
        tuiZoom.install(in: tuiClip, page: tuiHost, singleTap: tuiTap)
        // UI tests pinch on the full-screen app's area itself (a pinch on the
        // whole window starts its fingers outside it).
        tuiClip.accessibilityIdentifier = "terminal.tuiClip"
    }

    /// The surface's placement in the TUI host: its top-left and its scale.
    /// Zoomed: the zoom's pan; else the sideways pan and the cursor row's shift.
    func tuiSurfacePlacement() -> (origin: CGPoint, scale: CGFloat) {
        let zoom = tuiZoom.sync()
        if tuiZoomActive {
            tuiPanX = 0
            tuiRowShift = 0
            if model.zoomScale != zoom.scale { model.zoomScale = zoom.scale }
            return (CGPoint(x: -zoom.panX, y: -zoom.panY), CGFloat(zoom.scale))
        }
        if model.zoomScale != 1 { model.zoomScale = 1 }
        let layout = hostLayout
        tuiPanX = layout.clampPan(tuiPanX)
        tuiRowShift = layout.rowShift(keeping: surface.cursorViewportRow, from: tuiRowShift)
        return (CGPoint(x: -tuiPanX, y: -CGFloat(tuiRowShift) * cell.height), 1)
    }

    /// Places the surface at `origin`, scaled by `scale` (bounds stay the
    /// mirror's: Ghostty draws at its own size; the transform zooms it).
    func placeTUISurface(origin: CGPoint, scale: CGFloat) {
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        let size = surface.bounds.size
        let center = CGPoint(x: origin.x + size.width * scale / 2, y: origin.y + size.height * scale / 2)
        guard surface.transform != transform || surface.center != center else { return }
        UIView.performWithoutAnimation {
            surface.transform = transform
            surface.center = center
        }
    }

    /// The selection's and links' grid in the TUI host: cells at the zoom,
    /// from the surface's placement.
    var tuiGridPlacement: (cell: CGSize, padding: CGPoint) {
        let scale = tuiZoomActive ? CGFloat(tuiZoom.state.scale) : 1
        let origin = tuiZoomActive ? CGPoint(x: -tuiZoom.state.panX, y: -tuiZoom.state.panY)
            : CGPoint(x: -tuiPanX, y: -CGFloat(tuiRowShift) * cell.height)
        let padding = surface.gridPadding
        return (CGSize(width: cell.width * scale, height: cell.height * scale),
                CGPoint(x: origin.x + padding.x * scale, y: origin.y + padding.y * scale))
    }

    /// The letterbox under a zoomed grid shorter than the TUI area (nil:
    /// none, the grid fills it). Used instead of the unscaled layout's.
    var tuiZoomLetterbox: (top: CGFloat, height: CGFloat)? {
        guard let geometry = tuiZoomGeometry else { return nil }
        let top = CGFloat(geometry.gridHeight * tuiZoom.state.scale)
        let page = CGFloat(geometry.pageHeight)
        return top < page - 1 ? (top, page - top) : nil
    }

    /// One finger on a zoomed grid pans it; nothing reaches the app.
    func tuiZoomPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            tuiZoom.pan(translation: pan.translation(in: tuiClip), began: pan.state == .began)
        default:
            tuiZoom.panEnded()
        }
    }

    /// Typing on a zoomed grid follows the cursor.
    func tuiZoomFollowCursor() {
        guard let cursor = surface.visibleCursorCell else { return }
        tuiZoom.reveal(cursor, margin: CGFloat(TerminalHostGridLayout.cursorMargin) * cell.width * CGFloat(tuiZoom.state.scale))
    }

    /// The app entered or left the alternate screen: the surface is unscaled
    /// and the next one opens at fit width.
    func resetTUIZoom() {
        tuiZoom.reset()
        if !surface.transform.isIdentity {
            UIView.performWithoutAnimation { surface.transform = .identity }
        }
        if model.zoomScale != 1 { model.zoomScale = 1 }
    }
}
#endif
