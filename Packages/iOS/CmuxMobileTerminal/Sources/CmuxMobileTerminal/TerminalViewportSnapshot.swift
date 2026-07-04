#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

struct TerminalViewportSnapshot {
    let bounds: CGSize
    let containerSize: CGSize
    let keyboardOccupancy: CGFloat
    let composerFrame: CGRect
    let toolbarFrame: CGRect
    let layoutViewportRect: CGRect
    let liveViewportRect: CGRect

    func renderViewportRect(forRenderSize renderSize: CGSize, clampsStaleLiveViewport: Bool) -> CGRect {
        TerminalRenderViewportGeometry(
            layoutViewportRect: layoutViewportRect,
            liveViewportRect: liveViewportRect
        ).viewportRect(clampsStaleLiveViewport: clampsStaleLiveViewport)
    }

    func renderRect(forRenderSize renderSize: CGSize, clampsStaleLiveViewport: Bool) -> CGRect {
        let viewport = renderViewportRect(
            forRenderSize: renderSize,
            clampsStaleLiveViewport: clampsStaleLiveViewport
        )
        return CGRect(
            x: viewport.minX,
            y: viewport.maxY - renderSize.height,
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
