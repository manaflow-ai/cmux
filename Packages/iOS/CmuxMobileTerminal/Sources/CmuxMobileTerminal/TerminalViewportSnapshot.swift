#if canImport(UIKit)
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
        let targetHeight = layoutViewportRect.height
        let liveHeight = liveViewportRect.height
        let height = clampsStaleLiveViewport ? min(liveHeight, targetHeight) : liveHeight
        return CGRect(
            x: layoutViewportRect.minX,
            y: layoutViewportRect.minY,
            width: layoutViewportRect.width,
            height: max(1, height)
        )
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
