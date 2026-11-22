import AppKit
import CmuxNextDesign

/// The deliberate empty state for a workspace with no panes.
///
/// A workspace may be created by another client without its first terminal,
/// or may be waiting for the user after a prior terminal was closed.
final class EmptyWorkspaceView: NSView {
    var onNew: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: EmptyWorkspaceStrings.title)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    convenience init(onNew: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.onNew = onNew
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    private func build() {
        let title = titleLabel
        title.font = Typography.header
        title.alignment = .center

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space6),
        ])
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Colors resolve in this view's theme scope (its workspace's theme), and
    /// again when the theme or the window changes.
    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPlainReturn(event) {
            onNew?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isPlainReturn(event) {
            onNew?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isPlainReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
