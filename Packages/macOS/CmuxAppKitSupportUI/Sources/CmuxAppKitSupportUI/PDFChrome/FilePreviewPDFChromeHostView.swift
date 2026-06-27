public import AppKit

/// The transparent overlay-host `NSView` that sits above the PDF view and routes
/// pointer hits only into its registered interactive chrome overlays.
///
/// Its `hitTest` returns a hit only when the point lands on an `NSControl` or a
/// ``FilePreviewPDFChromeHostingView`` inside one of the visible
/// ``interactiveOverlayViews`` (searched front-to-back). Every other point
/// returns `nil`, so the host is click-through everywhere except the chrome
/// controls, letting the underlying PDF view receive the rest of the events.
public final class FilePreviewPDFChromeHostView: NSView {
    /// The overlay subtrees whose `NSControl`/``FilePreviewPDFChromeHostingView``
    /// descendants should receive pointer hits, searched front-to-back.
    public var interactiveOverlayViews: [NSView] = []

    override public func hitTest(_ point: NSPoint) -> NSView? {
        for overlayView in interactiveOverlayViews.reversed() where !overlayView.isHidden {
            let convertedPoint = convert(point, to: overlayView)
            if let hitView = interactiveHit(in: overlayView, at: convertedPoint) {
                return hitView
            }
        }
        return nil
    }

    private func interactiveHit(in view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden, view.bounds.contains(point) else { return nil }
        for subview in view.subviews.reversed() {
            let convertedPoint = view.convert(point, to: subview)
            if let hitView = interactiveHit(in: subview, at: convertedPoint) {
                return hitView
            }
        }
        return view is NSControl || view is FilePreviewPDFChromeHostingView ? view : nil
    }
}
