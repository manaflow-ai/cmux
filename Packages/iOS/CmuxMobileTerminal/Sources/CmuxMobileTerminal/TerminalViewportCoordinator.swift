#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

/// Single calculator for the iOS terminal viewport contract.
///
/// `GhosttySurfaceView` has several asynchronous participants: UIKit keyboard
/// animation, composer measurement, bottom chrome frames, Ghostty geometry
/// readback, and render-layer presentation. This coordinator turns the current
/// main-actor inputs into one immutable snapshot so every participant consumes
/// the same viewport for a frame.
@MainActor
struct TerminalViewportCoordinator {
    func snapshot(inputs: TerminalViewportInputs) -> TerminalViewportSnapshot {
        let bounds = CGSize(
            width: max(1, inputs.bounds.width),
            height: max(1, inputs.bounds.height)
        )
        let occupancy = TerminalLetterboxGeometry.keyboardOccupancy(
            keyboardHeight: inputs.keyboardHeight,
            bottomSafeAreaInset: inputs.bottomSafeAreaInset
        )
        let containerSize = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: bounds,
            keyboardHeight: inputs.keyboardHeight,
            composerBandHeight: inputs.composerBandHeight,
            toolbarHeight: inputs.reservedToolbarHeight,
            bottomSafeAreaInset: inputs.bottomSafeAreaInset,
            chromeHidden: inputs.chromeHidden
        )

        let bottomEdge = inputs.chromeHidden ? bounds.height : bounds.height - occupancy
        let effectiveComposerHeight = inputs.chromeHidden ? 0 : inputs.composerBandHeight
        let composerTop = bottomEdge - effectiveComposerHeight
        let composerFrame = CGRect(
            x: 0,
            y: max(0, composerTop),
            width: bounds.width,
            height: effectiveComposerHeight
        )
        let toolbarBottom = effectiveComposerHeight > 0 ? composerTop : bottomEdge
        let toolbarReservedTop = toolbarBottom - inputs.toolbarFrameHeight
        let toolbarTop = max(0, toolbarReservedTop)
        let toolbarFrame = CGRect(
            x: 0,
            y: toolbarTop,
            width: bounds.width,
            height: toolbarBottom - toolbarTop
        )

        let layoutViewport = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(1, containerSize.height)
        )
        let liveViewportHeight = Self.liveViewportHeight(
            inputs: inputs,
            boundsHeight: bounds.height,
            fallbackHeight: layoutViewport.height
        )
        return TerminalViewportSnapshot(
            bounds: bounds,
            containerSize: containerSize,
            keyboardOccupancy: occupancy,
            composerFrame: composerFrame,
            toolbarFrame: toolbarFrame,
            layoutViewportRect: layoutViewport,
            liveViewportRect: CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: liveViewportHeight
            )
        )
    }

    private static func liveViewportHeight(
        inputs: TerminalViewportInputs,
        boundsHeight: CGFloat,
        fallbackHeight: CGFloat
    ) -> CGFloat {
        guard inputs.chromeVisible,
              let frame = inputs.toolbarPresentationFrame ?? inputs.toolbarFrame,
              !frame.isNull,
              !frame.isEmpty else {
            return fallbackHeight
        }
        return min(max(1, frame.minY), max(1, boundsHeight))
    }
}

@MainActor
struct TerminalViewportInputs {
    let bounds: CGSize
    let keyboardHeight: CGFloat
    let composerBandHeight: CGFloat
    let reservedToolbarHeight: CGFloat
    let toolbarFrameHeight: CGFloat
    let bottomSafeAreaInset: CGFloat
    let chromeHidden: Bool
    let chromeVisible: Bool
    let toolbarFrame: CGRect?
    let toolbarPresentationFrame: CGRect?
}

@MainActor
struct TerminalViewportSnapshot {
    let bounds: CGSize
    let containerSize: CGSize
    let keyboardOccupancy: CGFloat
    let composerFrame: CGRect
    let toolbarFrame: CGRect
    let layoutViewportRect: CGRect
    let liveViewportRect: CGRect

    func renderViewportRect(forRenderSize renderSize: CGSize) -> CGRect {
        let targetHeight = layoutViewportRect.height
        let liveHeight = liveViewportRect.height
        let height: CGFloat
        if renderSize.height <= targetHeight + 1 {
            // Once Ghostty has produced a surface that fits the new container,
            // presentation-layer chrome from the previous layout may no longer
            // move the render bottom. This makes the "new render + old toolbar"
            // mixed state unrepresentable.
            height = min(liveHeight, targetHeight)
        } else {
            height = liveHeight
        }
        return CGRect(
            x: layoutViewportRect.minX,
            y: layoutViewportRect.minY,
            width: layoutViewportRect.width,
            height: max(1, height)
        )
    }

    func renderRect(forRenderSize renderSize: CGSize) -> CGRect {
        let viewport = renderViewportRect(forRenderSize: renderSize)
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
