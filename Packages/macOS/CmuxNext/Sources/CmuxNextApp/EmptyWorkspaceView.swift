import AppKit
import CmuxNextDesign

/// The deliberate empty state for a workspace with no panes.
///
/// A workspace may be created by another client without its first terminal,
/// or may be waiting for the user after a prior terminal was closed. When its
/// first terminal failed to start, it says why under the title (cx-tzlqb).
final class EmptyWorkspaceView: NSView {
    var onNew: (() -> Void)?
    /// Why the workspace's first terminal did not start; nil hides the line.
    var failure: String? {
        didSet {
            guard failure != oldValue else { return }
            detailLabel.stringValue = failure.map(EmptyWorkspaceStrings.failed) ?? ""
            detailLabel.isHidden = failure == nil
        }
    }

    private let titleLabel = ChromeLabel(labelWithString: EmptyWorkspaceStrings.title)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

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

        let detail = detailLabel
        detail.font = Typography.body
        detail.alignment = .center
        detail.isSelectable = true
        detail.focusRingType = .none
        detail.isHidden = true
        detail.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = Metrics.space3
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

    /// The failure line wraps to the view's width (at most 520 pt), so its
    /// height fits a narrow pane.
    override func layout() {
        let width = min(520, max(0, bounds.width - 2 * Metrics.space6))
        if detailLabel.preferredMaxLayoutWidth != width { detailLabel.preferredMaxLayoutWidth = width }
        super.layout()
    }

    // visibility-walk-allow: two label color stores in the theme scope, no layout or text measure; cheaper than a deferral
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
            detailLabel.textColor = Palette.textSecondary
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
