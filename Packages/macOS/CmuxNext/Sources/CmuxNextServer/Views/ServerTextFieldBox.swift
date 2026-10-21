import AppKit
import CmuxNextDesign

/// Holds a ``ServerTextField``'s AppKit field, centered vertically, and gives it the first
/// responder of the window it joins when asked to (once per window).
final class ServerTextFieldBox: NSView {
    let field: ThemedTextField
    private let autofocus: Bool
    private weak var focusedWindow: NSWindow?

    init(field: ThemedTextField, autofocus: Bool) {
        self.field = field
        self.autofocus = autofocus
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: field.intrinsicContentSize.height) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard autofocus, let window, focusedWindow !== window else { return }
        focusedWindow = window
        window.makeFirstResponder(field)
    }
}
