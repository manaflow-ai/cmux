public import AppKit
import CmuxNextWakeups

/// Vertical rubber band only when there is something to scroll to: a list
/// whose content fits neither scrolls nor bounces, and bounces again once
/// it overflows. macOS's `.automatic` is always
/// elastic vertically. Updates from the clip view's and the document's
/// frame notifications (no polling), observed through tokens that stop when
/// this object is released (no deinit).
@MainActor
public final class ScrollFitElasticity {
    private weak var scrollView: NSScrollView?
    private var observers: [FrameChangeObservation] = []
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
        // Synchronous (no queue): the elasticity is right before the next event (a hop only off main).
        observers.append(FrameChangeObservation(clip) { [weak self] in self?.update() })
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
        observers.append(FrameChangeObservation(document) { [weak self] in self?.update() })
    }
}

/// One view's frame-change observer, registered with no queue, that removes itself when released.
///
/// Not `MainActorObservation`: that registers on the main queue, so a post off the main thread
/// would block its thread until main ran the handler. Here a post on main runs `handler` inline
/// and a post from any other thread hands it to the main queue without waiting (`MainDelivery`).
/// `NotificationCenter.removeObserver(_:)` is thread-safe, so the deinit runs on any thread.
private nonisolated final class FrameChangeObservation {
    private let token: any NSObjectProtocol

    init(_ view: NSView, _ handler: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in
            MainDelivery().run(handler)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
