import AppKit

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

    /// The view that takes the keyboard when the tab is focused.
    var focusTarget: NSView { content }

    override var acceptsFirstResponder: Bool { false }
}
