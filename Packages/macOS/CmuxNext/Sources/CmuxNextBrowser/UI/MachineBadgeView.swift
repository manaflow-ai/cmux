import AppKit
import CmuxNextDesign

/// The subtle gray chip that names the machine whose localhost a tab sees
/// (plans/cmux-next/remote-localhost.md section 6), at the trailing end of
/// the omnibar. Hidden while the page is not a loopback origin.
final class MachineBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.caption
        label.textColor = Palette.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(text: String, help: String) {
        label.stringValue = text
        toolTip = help
        setAccessibilityLabel(help)
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.hoverFill.cgColor
            label.textColor = Palette.textSecondary
        }
    }
}
