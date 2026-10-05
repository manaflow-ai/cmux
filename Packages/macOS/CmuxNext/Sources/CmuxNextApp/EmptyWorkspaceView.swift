import AppKit
import CmuxNextDesign

/// The deliberate empty state for a workspace with no panes.
///
/// A workspace may be created by another client without its first terminal,
/// or may be waiting for the user after a prior terminal was closed. Keeping
/// the view action-only prevents cmux from silently creating a bare terminal.
final class EmptyWorkspaceView: NSView {
    var onNew: (() -> Void)?
    var onImportAndSync: (() -> Void)?

    private let newButton = NSButton()
    private let importButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: EmptyWorkspaceStrings.title)
    private let subtitleLabel = NSTextField(labelWithString: EmptyWorkspaceStrings.subtitle)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    convenience init(onNew: (() -> Void)? = nil, onImportAndSync: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.onNew = onNew
        self.onImportAndSync = onImportAndSync
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    private func build() {
        let title = titleLabel
        title.font = Typography.header
        title.alignment = .center

        let subtitle = subtitleLabel
        subtitle.font = Typography.body
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        for (button, title, selector, identifier) in [
            (newButton, EmptyWorkspaceStrings.new, #selector(newPressed), "cmux.empty-workspace.new"),
            (importButton, EmptyWorkspaceStrings.importAndSync, #selector(importPressed), "cmux.empty-workspace.import-and-sync"),
        ] {
            button.title = title
            button.target = self
            button.action = selector
            button.setAccessibilityIdentifier(identifier)
        }
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded

        let actions = NSStackView(views: [newButton, importButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Metrics.space2

        let stack = NSStackView(views: [title, subtitle, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space6),
        ])
        newButton.setAccessibilityLabel(EmptyWorkspaceStrings.new)
        importButton.setAccessibilityLabel(EmptyWorkspaceStrings.importAndSync)
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
            subtitleLabel.textColor = Palette.textSecondary
        }
    }

    override func becomeFirstResponder() -> Bool {
        newButton.becomeFirstResponder()
    }

    @objc private func newPressed() { onNew?() }
    @objc private func importPressed() { onImportAndSync?() }
}
