import AppKit
import CmuxNextDesign

/// What a pane shows for a tab whose one view another window shows (two windows on one space,
/// plans/cmux-next/spaces-overhaul-DESIGN.md rule 6): a page, a chat or a browser draws in one
/// place, so this window says where it is and offers to take it.
final class TabShownElsewhereView: NSView {
    private let label = ChromeLabel(labelWithString: WindowStrings.tabShownElsewhere)
    private let button = NSButton(title: WindowStrings.tabShowHere, target: nil, action: nil)
    private let onShowHere: () -> Void

    init(onShowHere: @escaping () -> Void) {
        self.onShowHere = onShowHere
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
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
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Takes the tab's view into this window (the button; tests).
    @objc func showHere() { onShowHere() }

    private func applyColors() {
        performWithTheme { label.textColor = Palette.textSecondary }
    }
}
