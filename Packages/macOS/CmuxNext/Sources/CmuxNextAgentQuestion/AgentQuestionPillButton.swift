import AppKit
import CmuxNextDesign

/// A capsule button in theme grays: the primary one fills with the text
/// color and inverts its label (no accent color), the secondary one is a
/// quiet hover fill.
final class AgentQuestionPillButton: NSButton {
    var isPrimary = false { didSet { applyColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // crash-allow: never decoded from a nib

    override var isEnabled: Bool { didSet { applyColors() } }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        performWithTheme {
            // The secondary fill is translucent by design: dim it, never make it opaque.
            let fill = isPrimary ? Palette.textPrimary : Palette.hoverFill
            let text = isPrimary ? Palette.windowBackground : Palette.textPrimary
            layer?.backgroundColor = fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : 0.35)).cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: text.withAlphaComponent(isEnabled ? 1 : 0.6),
                .font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
        }
    }
}
