#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

struct TerminalViewportSnapshot {
    let bounds: CGSize
    let containerSize: CGSize
    /// Points the dock's bottom edge sits above the screen bottom (keyboard
    /// when up, else the bottom safe-area fallback). Host/screen coordinate
    /// concern only; never part of the grid or render math.
    let keyboardOccupancy: CGFloat
    let composerFrame: CGRect
    let toolbarFrame: CGRect
    let layoutViewportRect: CGRect

    /// The render rect in surface coordinates: bottom-pinned to the viewport's
    /// bottom edge, which the host keeps glued to the dock top. Letterbox
    /// slack (whole-cell remainder or a daemon pin smaller than the viewport)
    /// shows at the top.
    func renderRect(forRenderSize renderSize: CGSize) -> CGRect {
        CGRect(
            x: layoutViewportRect.minX,
            y: layoutViewportRect.maxY - renderSize.height,
            width: renderSize.width,
            height: renderSize.height
        )
    }

    func isLetterboxed(renderSize: CGSize) -> Bool {
        renderSize.width + 0.5 < layoutViewportRect.width
            || renderSize.height + 0.5 < layoutViewportRect.height
    }
}
#endif
