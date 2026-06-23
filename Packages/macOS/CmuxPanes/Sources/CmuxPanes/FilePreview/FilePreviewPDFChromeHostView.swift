public import AppKit

/// Transparent overlay container for the floating PDF chrome.
///
/// Its `hitTest(_:)` only reports a hit for the registered interactive overlay
/// views (the sidebar and zoom chrome hosts) and the controls inside them, so
/// the rest of the overlay passes clicks through to the PDF view beneath it.
public final class FilePreviewPDFChromeHostView: NSView {
    /// The chrome hosting views whose controls should receive clicks; everything
    /// else in this overlay is click-through. Topmost (last) is tested first.
    public var interactiveOverlayViews: [NSView] = []

    /// Creates an empty chrome overlay with no interactive views registered.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    /// Convenience zero-frame initializer.
    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
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
