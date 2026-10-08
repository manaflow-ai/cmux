public import AppKit

/// Vertical rubber band only when there is something to scroll to: a list
/// whose content fits neither scrolls nor bounces, and bounces again once
/// it overflows. macOS's `.automatic` is always
/// elastic vertically. Updates from the clip view's and the document's
/// frame notifications (no polling).
@MainActor
public final class ScrollFitElasticity {
    private weak var scrollView: NSScrollView?
    private var observers: [any NSObjectProtocol] = []
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
        // Synchronous (no queue): the elasticity is right before the next event.
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: nil) {
            [weak self] _ in MainActor.assumeIsolated { self?.update() }
        })
        update()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) {
            [weak self] _ in MainActor.assumeIsolated { self?.update() }
        })
    }
}
