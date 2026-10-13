public import AppKit
import CmuxTheme

/// One Cmd-hold shortcut hint, drawn like cmux-classic's hint pill
/// (`ShortcutHintPill` / `SidebarShortcutHintPillView` on main): a capsule
/// with a Liquid Glass rim (``ShortcutHintChipStyle/glassRimWidth``) around
/// an opaque center, so the text keeps its contrast over any backdrop, and
/// a soft drop shadow. Before Liquid Glass, and under Reduce Transparency,
/// the opaque capsule carries a hairline border instead of the rim. The
/// outer view owns the shadow; the fill clips itself, so the capsule stays
/// round. Click-through and hidden from accessibility.
@MainActor
public final class ShortcutHintChipView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2

    private var glass: GlassPanelView?
    private let fill = NSView()
    private let label = NSTextField(labelWithString: "")
    private let reduceTransparency: ReduceTransparency

    public init(reduceTransparency: ReduceTransparency = .shared) {
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        fill.wantsLayer = true
        fill.layer?.masksToBounds = true
        fill.layer?.cornerCurve = .continuous
        addSubview(fill)
        label.font = Self.font
        label.alignment = .center
        label.lineBreakMode = .byClipping
        // A sibling above the glass, not its content: glass insets that view.
        addSubview(label)
        setAccessibilityElement(false)
        label.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var text: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            label.stringValue = newValue
            needsLayout = true
        }
    }

    /// The text in the chip's font plus padding, like classic's pill.
    public override var fittingSize: NSSize {
        let size = (label.stringValue as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: (size.width + Self.horizontalPadding * 2).rounded(.up),
                      height: (size.height + Self.verticalPadding * 2).rounded(.up))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// Re-reads the material (Reduce Transparency) and the theme; the
    /// overlay calls it each time the hints show.
    public func refresh() { needsLayout = true }

    public override func layout() {
        super.layout()
        let radius = bounds.height / 2
        let usesGlass = OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                                               reduceTransparency: reduceTransparency.isEnabled) == .liquidGlass
        if usesGlass {
            let glass = self.glass ?? makeGlass()
            glass.isHidden = false
            glass.frame = bounds
            glass.cornerRadius = radius
            let rim = ShortcutHintChipStyle.glassRimWidth
            fill.frame = bounds.insetBy(dx: rim, dy: rim)
            fill.layer?.cornerRadius = max(radius - rim, 0)
            fill.layer?.borderWidth = 0
        } else {
            glass?.isHidden = true
            fill.frame = bounds
            fill.layer?.cornerRadius = radius
            fill.layer?.borderWidth = ShortcutHintChipStyle.borderWidth
        }
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        performWithTheme {
            let dark = (ThemeContext.active ?? ThemeScope.app.tokens).isDark
            label.textColor = ShortcutHintChipStyle.foreground(dark: dark)
            fill.layer?.backgroundColor = ShortcutHintChipStyle.background(dark: dark).cgColor
            fill.layer?.borderColor = ShortcutHintChipStyle.border(dark: dark).cgColor
            layer?.shadowColor = ShortcutHintChipStyle.shadow.cgColor
        }
    }

    private func makeGlass() -> GlassPanelView {
        let glass = Glass.makePanel(style: .regular)
        glass.translatesAutoresizingMaskIntoConstraints = true
        // Untinted, like classic: the rim shows the backdrop.
        glass.tintColor = nil
        addSubview(glass, positioned: .below, relativeTo: fill)
        self.glass = glass
        return glass
    }
}

/// cmux-classic's `ShortcutHintPalette` (main `Sources/ShortcutHintPill.swift`),
/// keyed by the theme's dark or light scheme: opaque, so the text contrast
/// (10.4:1 dark, 15.1:1 light) never depends on what is behind the chip.
enum ShortcutHintChipStyle {
    /// Width of the Liquid Glass rim around the opaque center.
    static let glassRimWidth: CGFloat = 1.5
    /// The border of the opaque capsule without glass.
    static let borderWidth: CGFloat = 0.8
    static let shadow = NSColor.black.withAlphaComponent(0.22)

    static func foreground(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    }

    static func background(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    static func border(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
    }
}
