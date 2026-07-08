import AppKit

/// The canvas viewport: a plain `NSScrollView` configured for free 2D
/// panning. Using the real scroll machinery is what makes the canvas feel
/// native — trackpad momentum, rubber-banding, interruptible deceleration,
/// and pinch magnification all come from AppKit, driven by real scroll
/// events. Colors come from the host through ``CanvasTheme``.
@MainActor
final class CanvasScrollView: NSScrollView {
    init(documentView: CanvasDocumentView) {
        super.init(frame: .zero)
        self.documentView = documentView
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .allowed
        // Diagonal panning must not lock to the dominant axis.
        usesPredominantAxisScrolling = false
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 1.0
        drawsBackground = true
        contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
