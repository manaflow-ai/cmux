import AppKit
import CmuxNextDesign

/// Click-through shortcut badges shown while a modifier is held: one small
/// Liquid Glass chip per hint (`Glass.makeOverlayPanel`, so the opaque theme
/// fill under Reduce Transparency), right-aligned in its target rect. Text
/// contains only shortcut symbols.
final class ShortcutHintOverlayView: NSView {
    struct Hint: Equatable {
        var text: String
        var rect: CGRect
    }

    var hints: [Hint] = [] {
        didSet { if hints != oldValue { applyHints() } }
    }

    /// Chips are reused across modifier holds; only the count changes.
    private var badges: [ShortcutHintBadgeView] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyHints() {
        while badges.count > hints.count { badges.removeLast().removeFromSuperview() }
        while badges.count < hints.count {
            let badge = ShortcutHintBadgeView()
            addSubview(badge)
            badges.append(badge)
        }
        for (badge, hint) in zip(badges, hints) {
            badge.text = hint.text
            let size = badge.fittingSize
            badge.frame = CGRect(x: hint.rect.maxX - size.width - 2, y: hint.rect.midY - size.height / 2,
                                 width: size.width, height: size.height).integral
        }
    }
}

/// One hint chip: a non-interactive overlay surface (glass with the theme
/// tint) and the shortcut in the theme's primary text color above it.
final class ShortcutHintBadgeView: NSView {
    private static let height: CGFloat = 18
    private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    private let surface = Glass.makeOverlayPanel(interactive: false)
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        label.font = Self.font
        label.alignment = .center
        label.lineBreakMode = .byClipping
        // Above the material, not in its content view: glass insets that view.
        addSubview(label)
        setAccessibilityElement(false)
        label.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            label.stringValue = newValue
            needsLayout = true
        }
    }

    /// The text measured in the chip's font plus side padding, at a fixed height.
    override var fittingSize: NSSize {
        let width = (label.stringValue as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: (max(width, label.intrinsicContentSize.width) + Metrics.space2 * 2).rounded(.up), height: Self.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        performWithTheme { label.textColor = Palette.textPrimary }
    }
}
