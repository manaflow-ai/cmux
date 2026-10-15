public import AppKit

/// The view a page with in-pane DevTools hands its panel: it holds the page view and, while
/// DevTools are docked, the DevTools host view and the divider between them.
///
/// Not flipped, like ``BrowserDevToolsLayout``'s geometry: the bottom dock starts at y = 0.
public final class BrowserDevToolsPaneView: NSView {
    /// The page's view; it fills the page frame.
    public let pageView: NSView
    /// The controller that decides the frames; set by ``BrowserDevToolsPaneController``.
    weak var devTools: BrowserDevToolsPaneController?

    /// Creates a pane view around a page view.
    /// - Parameter pageView: The engine's page view.
    public init(pageView: NSView) {
        self.pageView = pageView
        super.init(frame: .zero)
        pageView.autoresizingMask = []
        addSubview(pageView)
        setAccessibilityIdentifier("browser.devtools.pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { false }

    override public func layout() {
        super.layout()
        let frames = devTools?.frames(in: bounds)
            ?? BrowserDevToolsLayoutFrames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        pageView.frame = frames.page
        devTools?.applyLayout(frames)
    }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}
