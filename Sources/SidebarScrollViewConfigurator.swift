import AppKit

/// Applies the sidebar workspace list's stable overlay-scroller configuration.
///
/// `SidebarScrollViewResolver` re-resolves on every SwiftUI update of the
/// sidebar, so `apply(to:)` is called repeatedly for the same scroll view —
/// including while AppKit is mid-way through an overlay-scroller fade. Any
/// write to these properties (even with an unchanged value) re-tiles the
/// scrollers and can cancel the in-flight fade without rescheduling it,
/// stranding the knob permanently visible (#3241 follow-up).
enum SidebarScrollViewConfigurator {
    static func apply(to scrollView: NSScrollView) {
        if scrollView.hasHorizontalScroller {
            scrollView.hasHorizontalScroller = false
        }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if !scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = true
        }
    }
}

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (`SidebarScrollViewResolver` in `ContentView.swift`), which applies the
/// configuration above through `onResolve`.
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
        // re-run the resolver — re-resolve immediately instead. The async
        // main hop in resolveScrollView() runs after AppKit's own synchronous
        // per-scroll-view reset regardless of observer registration order.
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
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
