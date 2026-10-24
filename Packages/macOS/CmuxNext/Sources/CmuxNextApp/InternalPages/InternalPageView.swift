import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSignposts

/// A native page's content whose keyboard goes to a view inside it (a Mac
/// Screen tab's input surface), not to the content view itself.
@MainActor
protocol InternalPageFocusing: NSView {
    var focusTarget: NSView { get }
}

/// A page tab's content: the provider's view filling the pane, under the
/// provider's optional native bar (``InternalPageProvider/makeTopBar(for:)``,
/// the Markdown omnibar), or above it with `browser.toolbarPosition` bottom.
/// `content` is the provider's view once it exists, so code that looks for
/// the page (`content as? PageWebView`) finds it with or without a bar. The
/// pane focuses `focusTarget` when the tab gets the keyboard; a click inside
/// the page moves the responder within it as usual.
///
/// A page opened from a key or an action is made placeholder first
/// (``init(key:page:topBar:makeContent:)``): the tab, its bar and an empty
/// area show in the key's own commit, and the provider's view (a web page, a
/// native page) is built just after that commit. Code that needs the view
/// (a route to open) waits for it with ``whenContent(_:)``.
final class InternalPageView: NSView {
    let key: String
    let page: InternalPageID
    /// The provider's view; nil while a placeholder-first page waits for it (``whenContent(_:)``).
    private(set) var content: NSView?
    /// The native bar above the content (below it, ``toolbarPosition``); it sets its own height.
    let topBar: NSView?
    /// The edge `topBar` sits on (`browser.toolbarPosition`); the pane sets it.
    var toolbarPosition: ToolbarPosition = .top {
        didSet {
            guard toolbarPosition != oldValue else { return }
            barEdge.activate(toolbarPosition)
            needsLayout = true
        }
    }
    /// The constraints that put `topBar` above or below the content; one set is active.
    private let barEdge = ToolbarEdgeConstraints()
    /// The view in the content's place: the content, or the empty area before it.
    private var placed: NSView?
    /// Builds the content after the commit that shows the tab; nil once it ran.
    private var makeContent: (@MainActor () -> NSView)?
    /// Work waiting for the content (``whenContent(_:)``).
    private var contentWaiters: [@MainActor (NSView) -> Void] = []

    /// A page whose content exists now.
    init(key: String, page: InternalPageID, content: NSView, topBar: NSView? = nil) {
        self.key = key
        self.page = page
        self.content = content
        self.topBar = topBar
        super.init(frame: .zero)
        installBar()
        place(content)
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
    }

    /// A placeholder-first page: `makeContent` runs once, after the Core Animation commit that ends this
    /// main run-loop turn (or earlier, when ``buildContent()`` is asked for). No page view is built in the
    /// key's turn.
    init(key: String, page: InternalPageID, topBar: NSView? = nil, makeContent: @escaping @MainActor () -> NSView,
         boundary: CommitBoundary = CommitBoundary()) {
        self.key = key
        self.page = page
        self.content = nil
        self.topBar = topBar
        self.makeContent = makeContent
        super.init(frame: .zero)
        installBar()
        place(NSView())
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
        boundary.after { [weak self] _ in self?.buildContent() }
    }

    /// Builds the content now if it does not exist yet (its after-commit build has not run), then runs
    /// the work waiting for it.
    func buildContent() {
        guard content == nil, let makeContent else { return }
        self.makeContent = nil
        let made = makeContent()
        let hadFocus = window?.firstResponder === self
        content = made
        place(made)
        if hadFocus { window?.makeFirstResponder(focusTarget) }
        let waiters = contentWaiters
        contentWaiters.removeAll()
        for waiter in waiters { waiter(made) }
    }

    /// Runs `body` with the content: now when it exists, else once it is built.
    func whenContent(_ body: @escaping @MainActor (NSView) -> Void) {
        if let content { return body(content) }
        contentWaiters.append(body)
    }

    private func installBar() {
        guard let topBar else { return }
        topBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Puts `view` in the content's place, replacing what was there.
    private func place(_ view: NSView) {
        NSLayoutConstraint.deactivate(barEdge.top + barEdge.bottom)
        placed?.removeFromSuperview()
        placed = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: topBar)
        if let topBar {
            barEdge.top = [
                topBar.topAnchor.constraint(equalTo: topAnchor),
                view.topAnchor.constraint(equalTo: topBar.bottomAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.bottom = [
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: topBar.topAnchor),
                topBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.activate(toolbarPosition)
        } else {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused: a native
    /// page's primary input (the docked Home's message box), a React page's
    /// web content itself, so typing reaches the page without a click first,
    /// or the view a native page names (``InternalPageFocusing``).
    var focusTarget: NSView {
        guard let content else { return self }
        if let input = (content as? any PrimaryInputTarget)?.primaryInputView { return input }
        if let page = content as? PageWebView { return page.focusView }
        return (content as? any InternalPageFocusing)?.focusTarget ?? content
    }

    /// While its content is not built yet the page holds the keyboard itself; the content takes it once
    /// it exists (``buildContent()``).
    override var acceptsFirstResponder: Bool { content == nil }

    /// Runs Go Back (true) or Go Forward (false): the mouse side buttons and a
    /// swipe over the page (history.md 4.2b). Set by the page's host.
    var navigate: ((Bool) -> Void)?

    /// Buttons 4 and 5 (AppKit numbers 3 and 4): Back and Forward, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        guard let navigate, event.buttonNumber == 3 || event.buttonNumber == 4 else { return super.otherMouseUp(with: event) }
        navigate(event.buttonNumber == 3)
    }

    /// A swipe to the right is Back, to the left Forward (WebKit's rule).
    override func swipe(with event: NSEvent) {
        guard let navigate, event.deltaX != 0 else { return super.swipe(with: event) }
        navigate(event.deltaX > 0)
    }
}

extension InternalPageView: ToolbarEdgeHosting {}
