import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The badge at the trailing end of the omnibar while the page is in browser
/// focus mode (classic cmux's toolbar mode chip): a keyboard glyph and "Focus
/// Mode", or "Esc again to exit" once the first Escape armed the exit.
/// Clicking it leaves focus mode.
final class FocusModeBadgeView: NSView {
    private let label = ChromeLabel(labelWithString: "")
    private let glyph = NSImageView()
    /// Runs on click: the host leaves focus mode.
    var onPress: (() -> Void)?
    /// The text shown now (tests).
    var shownText: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.caption
        label.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        // chrome-icons: allow Chrome has no focus mode; classic cmux's chip used the keyboard glyph.
        glyph.image = NSImage.icon(.keyboard, size: 12)
        glyph.image?.isTemplate = true
        addSubview(glyph)
        addSubview(label)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.browser.focusModeBadge")
        show(armed: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(armed: Bool) {
        label.stringValue = armed ? Strings.focusModeArmed : Strings.focusModeActive
        let help = Strings.focusModeExitHelp(Strings.focusModeEscapeHint)
        themedToolTip = help
        setAccessibilityLabel(label.stringValue)
        setAccessibilityHelp(help)
        needsDisplay = true
        updateLayer()
    }

    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
            label.textColor = NSColor.systemOrange
            glyph.contentTintColor = NSColor.systemOrange
        }
    }
}
