public import AppKit

/// Vertical rubber band only when there is something to scroll to: a list
/// whose content fits neither scrolls nor bounces, and bounces again once
/// it overflows. macOS's `.automatic` is always
/// elastic vertically. Updates from the scroll view's ``ScrollGeometryClipView``
/// resize hook (the clip or the document changed size): no notifications, no polling.
@MainActor
public final class ScrollFitElasticity: ScrollGeometryClient {
    private weak var scrollView: NSScrollView?

    /// The elasticity for a document `documentHeight` tall in a clip
    /// `visibleHeight` tall with `insets` (half a point of slack absorbs
    /// rounding).
    public nonisolated static func vertical(documentHeight: CGFloat, visibleHeight: CGFloat,
                                            insets: NSEdgeInsets = NSEdgeInsetsZero) -> NSScrollView.Elasticity {
        documentHeight + insets.top + insets.bottom > visibleHeight + 0.5 ? .allowed : .none
    }

    public init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        // Synchronous: the elasticity is right before the next event.
        ScrollGeometryClipView.install(in: scrollView).addClient(self)
        update()
    }

    /// A scroll leaves the fit as it was; a resize of the clip or the document re-reads it.
    public func scrollGeometryDidChange(_ change: ScrollGeometryChange) {
        if change.contains(.resized) { update() }
    }

    /// Re-reads the document and clip heights (a change of the content insets, which the clip does not report).
    public func update() {
        guard let scrollView else { return }
        let height = scrollView.documentView?.frame.height ?? 0
        let next = Self.vertical(documentHeight: height, visibleHeight: scrollView.contentView.bounds.height,
                                 insets: scrollView.contentInsets)
        if scrollView.verticalScrollElasticity != next { scrollView.verticalScrollElasticity = next }
    }
}
