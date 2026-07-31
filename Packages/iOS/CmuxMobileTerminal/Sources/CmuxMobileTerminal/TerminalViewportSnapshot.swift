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
    /// See `TerminalViewportInputs.viewportNegotiationUnsettled`.
    let viewportNegotiationUnsettled: Bool

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

    func renderRect(
        forRenderSize renderSize: CGSize,
        clampsStaleLiveViewport: Bool,
        cursorBottomInRender: CGFloat? = nil
    ) -> CGRect {
        let viewport = renderViewportRect(
            forRenderSize: renderSize,
            clampsStaleLiveViewport: clampsStaleLiveViewport
        )
        // Bottom-pin against the live viewport, but never clip content that
        // will be visible at settle: while the viewport grows (keyboard
        // dismissal) a target-sized render keeps its top row in place and the
        // keyboard reveals the lower rows, and while it shrinks (keyboard
        // rise) the old render slides only enough to keep the cursor row
        // visible instead of shoving every content row up by the keyboard
        // height (see `TerminalLetterboxGeometry.renderPinnedBottomEdge`).
        let bottomEdge = TerminalLetterboxGeometry.renderPinnedBottomEdge(
            liveViewportMaxY: viewport.maxY,
            targetViewportMaxY: layoutViewportRect.maxY,
            viewportMinY: viewport.minY,
            renderHeight: renderSize.height,
            holdsProvisionalPin: viewportNegotiationUnsettled,
            cursorBottomInRender: cursorBottomInRender
        )
        return CGRect(
            x: viewport.minX,
            y: bottomEdge - renderSize.height,
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

