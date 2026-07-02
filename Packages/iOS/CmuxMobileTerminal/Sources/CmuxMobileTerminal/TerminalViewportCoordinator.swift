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

        // Dock frames follow the LIVE keyboard edge while it moves (the sampled
        // guide position), and the target occupancy at steady state. The grid
        // reservation below stays on the target so the PTY resizes exactly once
        // per keyboard change while the chrome glides.
        let dockOccupancy = inputs.chromeHidden ? 0 : (inputs.liveBottomOccupancy ?? occupancy)
        let bottomEdge = max(0, inputs.chromeHidden ? bounds.height : bounds.height - dockOccupancy)
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
        let liveViewportHeight = liveViewportHeight(
            inputs: inputs,
            boundsHeight: bounds.height,
            fallbackHeight: layoutViewport.height,
            liveToolbarTop: inputs.liveBottomOccupancy != nil ? toolbarFrame.minY : nil
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

    private func liveViewportHeight(
        inputs: TerminalViewportInputs,
        boundsHeight: CGFloat,
        fallbackHeight: CGFloat,
        liveToolbarTop: CGFloat?
    ) -> CGFloat {
        guard inputs.chromeVisible else { return fallbackHeight }
        // Keyboard in motion: the toolbar frame just computed from the sampled
        // guide occupancy IS the live dock position (the dock is frame-set from
        // it this same tick), so the render viewport bottom sits exactly on it.
        if let liveToolbarTop {
            return min(max(1, liveToolbarTop), max(1, boundsHeight))
        }
        // Non-keyboard dock animations (HIDE/show, composer close) still move
        // the toolbar with UIView.animate, so follow its presentation frame.
        guard let frame = inputs.toolbarPresentationFrame ?? inputs.toolbarFrame,
              !frame.isNull,
              !frame.isEmpty else {
            return fallbackHeight
        }
        return min(max(1, frame.minY), max(1, boundsHeight))
    }

}
#endif
