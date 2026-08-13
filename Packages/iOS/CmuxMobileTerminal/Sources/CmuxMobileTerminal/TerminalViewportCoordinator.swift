#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

/// Single calculator for the iOS terminal viewport contract.
///
/// `GhosttySurfaceView` has several asynchronous participants: host-owned keyboard
/// presentation, composer measurement, and Ghostty geometry readback. This
/// coordinator turns the current
/// main-actor inputs into one immutable snapshot so every participant consumes
/// the same viewport for a frame.
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

        let bottomEdge = max(0, inputs.chromeHidden ? bounds.height : bounds.height - occupancy)
        let effectiveComposerHeight = inputs.chromeHidden ? 0 : inputs.composerBandHeight
        let composerTop = bottomEdge - effectiveComposerHeight
        let composerY = max(0, composerTop)
        let composerFrame = CGRect(
            x: 0,
            y: composerY,
            width: bounds.width,
            height: max(0, bottomEdge - composerY)
        )
        let toolbarBottom = effectiveComposerHeight > 0 ? composerFrame.minY : bottomEdge
        let toolbarReservedTop = toolbarBottom - inputs.toolbarFrameHeight
        let toolbarTop = max(0, toolbarReservedTop)
        let toolbarFrame = CGRect(
            x: 0,
            y: toolbarTop,
            width: bounds.width,
            height: max(0, toolbarBottom - toolbarTop)
        )

        let layoutViewport = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(1, containerSize.height)
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
                height: layoutViewport.height
            ),
            viewportNegotiationUnsettled: inputs.viewportNegotiationUnsettled
        )
    }

}
#endif
