#if canImport(UIKit)
import CoreGraphics

struct TerminalViewportInputs {
    let bounds: CGSize
    /// Live keyboard overlap in points. Seats the dock's bottom constraint
    /// only; the grid container and render placement never consume it.
    let keyboardHeight: CGFloat
    let composerBandHeight: CGFloat
    let reservedToolbarHeight: CGFloat
    let toolbarFrameHeight: CGFloat
    let bottomSafeAreaInset: CGFloat
    let chromeHidden: Bool
    /// The top safe-area band included in `bounds` when the surface extends
    /// under the navigation bar for the scroll-edge band (0 otherwise). The
    /// grid container excludes it; the render layer's overscan band fills it.
    let topContentInset: CGFloat
}
#endif
