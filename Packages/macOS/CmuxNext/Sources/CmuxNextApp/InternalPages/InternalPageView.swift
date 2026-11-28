import AppKit
import CmuxNextPages

/// A page tab's content: the provider's view filling the pane. The pane
/// focuses `focusTarget` when the tab gets the keyboard; a click inside the
/// page moves the responder within it as usual.
final class InternalPageView: NSView {
    let key: String
    let page: InternalPageID
    let content: NSView

    init(key: String, page: InternalPageID, content: NSView) {
        self.key = key
        self.page = page
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused: a React page's
    /// web content itself, so typing reaches the page without a click first.
    var focusTarget: NSView { (content as? PageWebView)?.webKitView ?? content }

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
