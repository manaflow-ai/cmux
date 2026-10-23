public import AppKit
import CmuxNextCompat

/// Vertical rubber band only when there is something to scroll to: a list
/// whose content fits neither scrolls nor bounces, and bounces again once
/// it overflows. macOS's `.automatic` is always
/// elastic vertically. Updates from the clip view's and the document's
/// frame notifications (no polling), observed through tokens that stop when
/// this object is released (no deinit).
@MainActor
public final class ScrollFitElasticity {
    private weak var scrollView: NSScrollView?
    private var observers: [MainActorObservation] = []
    private weak var observedDocument: NSView?

    /// The elasticity for a document `documentHeight` tall in a clip
    /// `visibleHeight` tall with `insets` (half a point of slack absorbs
    /// rounding).
    public nonisolated static func vertical(documentHeight: CGFloat, visibleHeight: CGFloat,
                                            insets: NSEdgeInsets = NSEdgeInsetsZero) -> NSScrollView.Elasticity {
        documentHeight + insets.top + insets.bottom > visibleHeight + 0.5 ? .allowed : .none
    }

    public init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsFrameChangedNotifications = true
        // AppKit posts frame changes on main, where a `queue: .main` observer runs inline: the
        // elasticity is right before the next event.
        observers.append(MainActorObservation(NSView.frameDidChangeNotification, object: clip) { [weak self] in
            self?.update()
        })
        update()
    }

    /// Re-reads the document and clip heights; call after the document
    /// changes size when its frame notifications are off.
    public func update() {
        guard let scrollView else { return }
        observeDocument(scrollView.documentView)
        let height = scrollView.documentView?.frame.height ?? 0
        let next = Self.vertical(documentHeight: height, visibleHeight: scrollView.contentView.bounds.height,
                                 insets: scrollView.contentInsets)
        if scrollView.verticalScrollElasticity != next { scrollView.verticalScrollElasticity = next }
    }

    private func observeDocument(_ document: NSView?) {
        guard let document, document !== observedDocument else { return }
        observedDocument = document
        document.postsFrameChangedNotifications = true
        observers.append(MainActorObservation(NSView.frameDidChangeNotification, object: document) { [weak self] in
            self?.update()
        })
    }
}
