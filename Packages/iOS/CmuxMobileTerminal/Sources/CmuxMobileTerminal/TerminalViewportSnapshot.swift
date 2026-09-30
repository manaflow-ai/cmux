#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

struct TerminalViewportSnapshot: Equatable, Sendable {
    let bounds: CGSize
    let containerSize: CGSize
    /// Points the dock's bottom edge sits above the screen bottom (keyboard
    /// when up, else the bottom safe-area fallback). Host/screen coordinate
    /// concern only; never part of the grid or render math.
    let keyboardOccupancy: CGFloat
    let composerFrame: CGRect
    let toolbarFrame: CGRect
    let layoutViewportRect: CGRect
    let renderTopInset: CGFloat

    /// The render rect in surface coordinates
    /// (`TerminalLetterboxGeometry.renderRect`): a grid at least one row
    /// shorter than the viewport (a daemon pin) is top-pinned with its slack
    /// below; the natural grid stays bottom-pinned to the viewport's bottom
    /// edge, which the host keeps glued to the dock top, with its sub-row
    /// remainder at the top.
    func renderRect(forRenderSize renderSize: CGSize, cellHeight: CGFloat) -> CGRect {
        TerminalLetterboxGeometry.renderRect(renderSize: renderSize, in: layoutViewportRect, cellHeight: cellHeight)
    }

    func isLetterboxed(renderSize: CGSize) -> Bool {
        renderSize.width + 0.5 < layoutViewportRect.width
            || renderSize.height + 0.5 < layoutViewportRect.height
    }
}
#endif
