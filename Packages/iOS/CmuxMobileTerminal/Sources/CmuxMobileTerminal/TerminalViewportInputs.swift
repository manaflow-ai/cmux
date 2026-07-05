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
}
#endif

