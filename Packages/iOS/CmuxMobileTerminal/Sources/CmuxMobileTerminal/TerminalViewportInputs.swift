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
    /// True while the shared-grid negotiation is unsettled: a keyboard
    /// transition is in flight, a capacity report is debouncing, or the
    /// newest report's echo has not confirmed. The render pin treats the
    /// current effective grid as provisional then (see
    /// `TerminalLetterboxGeometry.renderPinnedBottomEdge`).
    let viewportNegotiationUnsettled: Bool
}
#endif
