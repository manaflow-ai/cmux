public import AppKit

/// What a pane shows for a tab whose one view another window shows (two windows on one space,
/// plans/cmux-next/spaces-overhaul-DESIGN.md rule 6): a page, a chat or a browser draws in one
/// place, so this window says where it is and offers to take it.
public final class TabShownElsewhereView: NSView, PaneCommitMotionPicture {
    private let label: ChromeLabel
    private let button: NSButton
    private let onShowHere: @MainActor () -> Void

    /// `message` says where the tab is; `action` names the button that takes it (the app's strings).
    public init(message: String, action: String, onShowHere: @escaping @MainActor () -> Void) {
        label = ChromeLabel(labelWithString: message)
        button = NSButton(title: action, target: nil, action: nil)
        self.onShowHere = onShowHere
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Typography.system(.default, size: TypeScale.body, weight: TypeScale.emphasis)
        label.lineBreakMode = .byTruncatingTail
        button.bezelStyle = .rounded
        (button.target, button.action) = (self, #selector(showHere))
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.stringValue)
        applyColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Takes the tab's view into this window (the button; tests).
    @objc public func showHere() { onShowHere() }

    private func applyColors() {
        performWithTheme { label.textColor = Palette.textSecondary }
    }
}
