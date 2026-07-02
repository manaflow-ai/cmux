#if canImport(UIKit)
import CoreGraphics

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
    /// The bottom occupancy sampled from the keyboard-layout-guide anchor's
    /// presentation layer THIS frame, or nil at steady state. When set, the
    /// dock frames and live viewport are placed at this ground-truth keyboard
    /// position; the grid reservation (`layoutViewportRect`) still uses the
    /// target `keyboardHeight` so the PTY resizes once, not per frame.
    let liveBottomOccupancy: CGFloat?
}
#endif

