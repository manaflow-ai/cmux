import AppKit
import CmuxNextDesign

/// What an agent chat tab shows on a Mac that does not run its session: the session lives in
/// another Mac's acpmux, and only that Mac attaches to it ("This chat runs on <machine>").
final class AgentTabElsewhereView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(machine: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        label.stringValue = machine.map(RemoteStrings.agentTabElsewhere) ?? RemoteStrings.agentTabElsewhereUnknown
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Colors resolve in this view's theme scope (its workspace's theme).
    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textTertiary
            label.textColor = Palette.textSecondary
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The text it shows.
    var message: String { label.stringValue }
}
