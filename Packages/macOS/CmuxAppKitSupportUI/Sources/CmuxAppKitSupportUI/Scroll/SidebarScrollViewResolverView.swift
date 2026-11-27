public import AppKit

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (``SidebarScrollViewResolver``), which applies the overlay configuration in
/// ``AppKit/NSScrollView/applySidebarOverlayScrollerConfiguration()`` through
/// `onResolve`.
public final class SidebarScrollViewResolverView: NSView {
    /// Invoked with the resolved enclosing scroll view (or `nil`) after each
    /// deferred resolution hop.
    public var onResolve: ((NSScrollView?) -> Void)?
    // The observer token is only ever assigned/read on the main thread (this is
    // a main-thread-only NSView); the lone exception is its removal in the
    // nonisolated deinit, which is safe because deinit runs after all main-thread
    // access has ceased. `nonisolated(unsafe)` keeps that one cross-isolation
    // read legal under Swift 6 without weakening the type.
    private nonisolated(unsafe) var scrollerStyleObserver: (any NSObjectProtocol)?

    /// Creates the resolver view and begins observing scroller-style changes.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit resets every NSScrollView's scrollerStyle to the new system
        // preference when the preferred scroller style changes (mouse
        // connect/disconnect, System Settings "Show scroll bars"). That
        // clobbers the forced overlay configuration with a legacy,
        // space-reserving scrollbar until the next SwiftUI update happens to
        // re-run the resolver — re-resolve immediately instead. The .main
        // queue keeps the block on the main thread for any posting thread,
        // and the async main hop in resolveScrollView() runs after AppKit's
        // own synchronous per-scroll-view reset regardless of observer
        // registration order.
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resolveScrollView()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let scrollerStyleObserver {
            NotificationCenter.default.removeObserver(scrollerStyleObserver)
        }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    /// Resolves the enclosing scroll view after one deferred main-actor hop so
    /// the view hierarchy settles and any AppKit scroller-style reset lands
    /// before the configuration is re-applied.
    ///
    /// `nonisolated` so it can be invoked from the `NotificationCenter` observer
    /// closure (a `@Sendable` context) without a synchronous main-actor call;
    /// the body only schedules a `@MainActor` `Task`, so it performs no isolated
    /// work itself and the actual resolution still runs on the main actor.
    public nonisolated func resolveScrollView() {
        // Deferred one main-actor hop so the view hierarchy settles before
        // enclosingScrollView is resolved and, on scroller-style changes,
        // AppKit's own synchronous per-scroll-view reset lands before the
        // configuration is re-applied.
        Task { @MainActor [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}
