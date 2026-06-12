import AppKit

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (`SidebarScrollViewResolver` in `ContentView.swift`), which applies
/// `SidebarScrollViewConfigurator`'s overlay configuration through
/// `onResolve`.
final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?
    private var scrollerStyleObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let scrollerStyleObserver {
            NotificationCenter.default.removeObserver(scrollerStyleObserver)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}
