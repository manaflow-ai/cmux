import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A native page's content whose keyboard goes to a view inside it (a Mac
/// Screen tab's input surface), not to the content view itself.
@MainActor
protocol InternalPageFocusing: NSView {
    var focusTarget: NSView { get }
}

/// A page tab's content: the provider's view filling the pane, under the
/// provider's optional native bar (``InternalPageProvider/makeTopBar(for:)``,
/// the Markdown omnibar), or above it with `browser.toolbarPosition` bottom. `content` is always the provider's view, so code
/// that looks for the page (`content as? PageWebView`) finds it with or without
/// a bar. The pane focuses `focusTarget` when the tab gets the keyboard; a
/// click inside the page moves the responder within it as usual.
final class InternalPageView: NSView {
    let key: String
    let page: InternalPageID
    let content: NSView
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

    init(key: String, page: InternalPageID, content: NSView, topBar: NSView? = nil) {
        self.key = key
        self.page = page
        self.content = content
        self.topBar = topBar
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        if let topBar {
            topBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(topBar)
            NSLayoutConstraint.activate([
                topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            barEdge.top = [
                topBar.topAnchor.constraint(equalTo: topAnchor),
                content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.bottom = [
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: topBar.topAnchor),
                topBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.activate(toolbarPosition)
        } else {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused: a native
    /// page's primary input (the docked Home's message box), a React page's
    /// web content itself, so typing reaches the page without a click first,
    /// or the view a native page names (``InternalPageFocusing``).
    var focusTarget: NSView {
        if let input = (content as? any PrimaryInputTarget)?.primaryInputView { return input }
        if let page = content as? PageWebView { return page.focusView }
        return (content as? any InternalPageFocusing)?.focusTarget ?? content
    }

    override var acceptsFirstResponder: Bool { false }

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
