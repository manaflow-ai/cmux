import AppKit
import CmuxNextDesign

/// The Chief's first-open message at the top of the empty Chief conversation (`HomeFirstRunView`):
/// a Chief bubble with the fixed intro text. It rises and fades in once when it is shown, on the
/// Home motion gate (Reduce Motion skips the rise). `ChiefIntroStore` decides whether it shows.
final class HomeFirstRunIntro: NSView {
    let label = ChromeLabel(wrappingLabelWithString: "")
    private var scale: CGFloat = 1

    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    /// How far the bubble rises into place, in points before the interface scale.
    static let rise: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        label.font = .systemFont(ofSize: TypeScale.Base.detail)
        label.alignment = .left
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        // The text is the element VoiceOver reads; the bubble itself adds nothing (as the hero does).
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Sets the intro text.
    func setText(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        needsLayout = true
    }

    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        label.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyColors(text: NSColor, fill: NSColor) { // theme-scoped
        label.textColor = text
        layer?.backgroundColor = fill.cgColor
    }

    /// The bubble's height in a column `width` wide: the wrapped text and its padding.
    func height(for width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * Self.padding * scale)
        return ceil(label.size(forWidth: inner).height) + 2 * Self.padding * scale
    }

    /// Plays the one-time entrance: the bubble rises and fades in. The gate sets the duration, skips
    /// the rise under Reduce Motion, and shows the bubble in place when animation is off.
    func animateIn() {
        guard let layer else { return }
        Motion.home.set(layer, "transform.translation.y", to: CGFloat(0), movementFade: .fadeIn, from: Self.rise * scale)
        Motion.home.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.padding * scale, dy: Self.padding * scale)
    }
}
