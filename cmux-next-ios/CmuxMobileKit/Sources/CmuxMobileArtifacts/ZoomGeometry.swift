import CoreGraphics

/// The image viewer's zoom rules, kept apart from UIKit so they are unit tested.
public struct ZoomGeometry: Equatable, Sendable {
    public var minimumScale: CGFloat = 1
    public var maximumScale: CGFloat = 4
    /// Double-tap zoom from the fitted image.
    public var doubleTapScale: CGFloat = 2.5

    public init() {}

    /// Zoomed in past the fitted size (pans the image; the dismiss swipe is off).
    public func isZoomed(_ scale: CGFloat) -> Bool { scale > minimumScale + 0.01 }

    /// Where a double-tap goes: back to the fitted image when zoomed in, otherwise to
    /// `doubleTapScale` centered on the tapped point. The rect is in the zoomed view's
    /// (unscaled) coordinates, for `UIScrollView.zoom(to:animated:)`; `nil` = fit.
    public func doubleTapTarget(scale: CGFloat, tap: CGPoint, viewSize: CGSize) -> CGRect? {
        guard !isZoomed(scale) else { return nil }
        let width = viewSize.width / doubleTapScale
        let height = viewSize.height / doubleTapScale
        return CGRect(x: tap.x - width / 2, y: tap.y - height / 2, width: width, height: height)
    }

    /// Insets that center content smaller than the viewport.
    public func centeringInsets(content: CGSize, viewport: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(0, (viewport.width - content.width) / 2), max(0, (viewport.height - content.height) / 2))
    }
}
