#if canImport(UIKit)
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// Display of a shared grid larger than this phone.
///
/// The surface renders the exact shared grid at full size (so the byte stream
/// and render-grid replays match it), and the renderer layer is displayed
/// scaled down to the viewport width. A pinch magnifies around the fingers up
/// to 1:1 and moving the fingers pans; neither touches libghostty, the PTY
/// grid, or the font.
extension GhosttySurfaceView {
    /// The scaled-grid layout for `viewport`, from the stored pinch state.
    func scaledGridLayout(in viewport: CGRect) -> TerminalScaledGridLayout? {
        guard let gridSize = scaledGridRenderSize else { return nil }
        return TerminalScaledGridLayout(
            gridSize: gridSize,
            viewport: viewport,
            magnification: scaledGridMagnification,
            offset: scaledGridOffset
        )
    }

    /// Where the grid displays for `snapshot`, updating the display scale
    /// and the clamped pinch state. Outside the scaled mode this is the
    /// bottom-pinned letterbox rect for `renderSize`.
    func resolveGridRenderRect(for snapshot: TerminalViewportSnapshot, renderSize: CGSize) -> CGRect {
        guard let layout = scaledGridLayout(in: snapshot.layoutViewportRect) else {
            gridDisplayScale = 1
            return snapshot.renderRect(forRenderSize: renderSize)
        }
        scaledGridMagnification = layout.magnification
        scaledGridOffset = layout.offset
        gridDisplayScale = layout.displayScale
        return layout.displayRect
    }

    /// The renderer layer's bounds and transform for a displayed rect. The
    /// bounds are always the drawable's exact size in points: the present
    /// path discards a frame whose surface size differs from them.
    func rendererLayerPlacement(displayRect: CGRect) -> (boundsSize: CGSize, transform: CATransform3D) {
        guard let gridSize = scaledGridRenderSize, gridDisplayScale != 1 else {
            return (displayRect.size, CATransform3DIdentity)
        }
        let size = CGSize(
            width: gridSize.width,
            height: gridSize.height + appliedRenderTopInsetPts + appliedRenderBottomInsetPts
        )
        return (size, CATransform3DMakeScale(gridDisplayScale, gridDisplayScale, 1))
    }

    /// Drives a pinch while the grid is scaled to fit. Returns false when the
    /// pinch should change the font instead.
    func handleScaledGridPinch(_ gesture: UIPinchGestureRecognizer) -> Bool {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard scaledGridRenderSize != nil else {
                scaledGridPinchStart = nil
                return false
            }
            scaledGridPinchStart = (scaledGridMagnification, location)
            return true
        case .changed:
            guard let start = scaledGridPinchStart,
                  let viewport = lastLetterboxViewportRect,
                  let layout = scaledGridLayout(in: viewport) else {
                return scaledGridPinchStart != nil
            }
            // Pan by the fingers' movement since the last step, then magnify
            // around where they are now.
            let previous = gesture.numberOfTouches >= 2 ? start.location : location
            let next = layout
                .panned(by: CGPoint(x: location.x - previous.x, y: location.y - previous.y))
                .zoomed(to: start.magnification * gesture.scale, about: location)
            scaledGridPinchStart = (start.magnification, location)
            scaledGridMagnification = next.magnification
            scaledGridOffset = next.offset
            layoutRenderedTerminalForCurrentViewport()
            return true
        case .ended, .cancelled, .failed:
            let handled = scaledGridPinchStart != nil
            scaledGridPinchStart = nil
            return handled
        default:
            return scaledGridPinchStart != nil
        }
    }
}
#endif
