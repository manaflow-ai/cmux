public import AppKit

/// `NSHostingView` that hosts the omnibar suggestions popup overlay inside the
/// in-window browser portal and forwards hits only over the popup rectangle.
///
/// The overlay fills the whole portal so the popup can sit anywhere, but only
/// the `popupFrameInTopLeftCoordinates` rectangle is interactive; `hitTest`
/// returns `nil` everywhere else so clicks pass through to the web content
/// behind the overlay. The frame is supplied in the portal's top-left
/// coordinate space, so the test flips the incoming point when the view is not
/// flipped.
public final class BrowserPortalOmnibarSuggestionsHostingView: NSHostingView<BrowserPortalOmnibarSuggestionsOverlay> {
    /// Interactive popup rectangle in the portal's top-left coordinate space.
    public var popupFrameInTopLeftCoordinates: CGRect = .zero

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let topLeftPoint: NSPoint
        if isFlipped {
            topLeftPoint = point
        } else {
            topLeftPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        }
        guard popupFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
}
