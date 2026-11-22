public import AppKit
public import CmuxNextPages

/// The window content of one Cloud creation (cx-lu8f): the React progress page
/// (``CloudProgressPageProvider``) and the creation it shows. Swift keeps only this bridge (Leo,
/// 2026-11-06: "btw we ought to have a lot of that ui in react and not swift"); the page draws the
/// steps, the time so far, the detail and Retry, Copy Error and Dismiss. The window code finds the
/// shown creation by ``source``. Keys typed before the terminal exists go to the page, which says so;
/// none reach a hidden pane. The App makes it a first-paint-gated view (transparent until the page
/// paints, like a page tab).
@MainActor
public final class CloudProgressHost: NSView {
    public let source: any CloudProgressSource
    public let provider: CloudProgressPageProvider
    private let page: PageWebView?
    public init(source: any CloudProgressSource, actions: CloudProgressPageProvider.Actions) {
        self.source = source
        provider = CloudProgressPageProvider(source: source, actions: actions)
        page = PageWebView(descriptor: .cloudProgress, routes: [PageRoute(prefix: "cmux.cloudProgress.", provider: provider)])
        super.init(frame: .zero)
        if let page {
            page.frame = bounds
            page.autoresizingMask = [.width, .height]
            addSubview(page)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.cloud.creation.progress")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var acceptsFirstResponder: Bool { true }

    /// A page that leaves its window (the workspace opened, the window closed) answers its open question no.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { provider.answer(nil, accept: false) }
    }

    override public func becomeFirstResponder() -> Bool {
        guard let page else { return true }
        return window?.makeFirstResponder(page.webKitView) ?? true
    }

    /// The page has not painted its first frame yet.
    public var awaitsFirstPaint: Bool { page.map { !$0.hasPainted } ?? false }

    /// Runs `body` once the page has painted (now if it has, or if there is no page).
    public func whenFirstPainted(_ body: @escaping () -> Void) {
        guard let page else { return body() }
        page.whenPainted(body)
    }
}
