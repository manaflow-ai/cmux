#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics

/// Single calculator for the iOS terminal viewport contract.
///
/// `GhosttySurfaceView` has several asynchronous participants: host-owned dock
/// placement, composer measurement, and Ghostty geometry readback. This
/// coordinator turns the current main-actor inputs into one immutable snapshot
/// so every participant consumes the same viewport for a frame.
///
/// The keyboard is NOT a grid input. The terminal grid always has its
/// keyboard-down size; the host translates the rendered terminal so its bottom
/// edge rides the dock (composer bar) when the keyboard is up. In surface
/// coordinates the dock therefore always sits directly below the viewport,
/// which is why `composerFrame` and `toolbarFrame` stack under
/// `layoutViewportRect` regardless of keyboard state. `keyboardOccupancy` is
/// exposed solely for seating the dock's bottom constraint in host/screen
/// coordinates.
struct TerminalViewportCoordinator {
    func snapshot(inputs: TerminalViewportInputs) -> TerminalViewportSnapshot {
        let bounds = CGSize(
            width: max(1, inputs.bounds.width),
            height: max(1, inputs.bounds.height)
        )
        // Dock seat below the screen bottom edge: the live keyboard when up,
        // else the bottom safe area so the always-visible toolbar clears the
        // home indicator. With the chrome hidden nothing needs to clear the
        // home indicator; only an actual keyboard seats the (invisible) dock.
        let occupancy = inputs.chromeHidden
            ? max(0, inputs.keyboardHeight)
            : TerminalLetterboxGeometry.keyboardOccupancy(
                keyboardHeight: inputs.keyboardHeight,
                bottomSafeAreaInset: inputs.bottomSafeAreaInset
            )
        let topContentInset = max(0, inputs.topContentInset)
        let containerSize = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: bounds,
            composerBandHeight: inputs.composerBandHeight,
            toolbarHeight: inputs.reservedToolbarHeight,
            bottomSafeAreaInset: inputs.bottomSafeAreaInset,
            chromeHidden: inputs.chromeHidden,
            topContentInset: topContentInset
        )

        // The grid viewport starts below the top scroll-edge band; the band
        // above it belongs to the render layer's overscan rows only.
        let layoutViewport = CGRect(
            x: 0,
            y: topContentInset,
            width: bounds.width,
            height: max(1, containerSize.height)
        )
        // Dock frames in SURFACE coordinates: the toolbar rides the viewport's
        // bottom edge and the composer band sits below it, in every keyboard
        // state. Keyboard motion moves the whole surface (the host's render
        // wrapper) instead of these frames, so surface-internal chrome stays
        // glued to the dock without keyboard math.
        let effectiveToolbarHeight = inputs.chromeHidden ? 0 : max(0, inputs.toolbarFrameHeight)
        let effectiveComposerHeight = inputs.chromeHidden ? 0 : max(0, inputs.composerBandHeight)
        let toolbarFrame = CGRect(
            x: 0,
            y: layoutViewport.maxY,
            width: bounds.width,
            height: effectiveToolbarHeight
        )
        let composerFrame = CGRect(
            x: 0,
            y: toolbarFrame.maxY,
            width: bounds.width,
            height: effectiveComposerHeight
        )
        return TerminalViewportSnapshot(
            bounds: bounds,
            containerSize: containerSize,
            keyboardOccupancy: occupancy,
            composerFrame: composerFrame,
            toolbarFrame: toolbarFrame,
            layoutViewportRect: layoutViewport
        )
    }

}
#endif
