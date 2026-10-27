public import AppKit
import CmuxTheme

/// One modifier-hold shortcut hint (Cmd, Ctrl or Option held): a Liquid
/// Glass capsule (`NSGlassEffectView` through ``GlassPanelView``) with the
/// theme's glass tint (half again as strong as a panel's), so the chip takes
/// the theme's cast and the theme's primary text stays legible over it (Lawrence 2026-10-14: "liquid
/// glassy"). The material follows ``OverlayMaterial``: before macOS 26 the
/// same panel draws a blur with the tint and a hairline; under Reduce
/// Transparency the chip is the theme's opaque popup surface with a hairline
/// and a soft drop shadow. Click-through and hidden from accessibility.
@MainActor
public final class ShortcutHintChipView: NSView {
    private static let font = CheckedFont.resolve(size: 10) { .monospacedDigitSystemFont(ofSize: 10, weight: .semibold) }
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2

    private var glass: GlassPanelView?
    private let fill = NSView()
    private let label = ChromeLabel(labelWithString: "")
    private let reduceTransparency: ReduceTransparency

    public init(reduceTransparency: ReduceTransparency = .shared) {
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        fill.wantsLayer = true
        fill.layer?.masksToBounds = true
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
            needsLayout = true // invalidate: new text (the guard above); the label sits at its text's height.
        }
    }

    /// The text in the chip's font plus padding, like classic's pill.
    public override var fittingSize: NSSize {
        let size = (label.stringValue as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: (size.width + Self.horizontalPadding * 2).rounded(.up),
                      height: (size.height + Self.verticalPadding * 2).rounded(.up))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true }
    }

    // visibility-walk-allow: one invalidation; AppKit lays out only views on screen, so a hidden chip pays nothing
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true // invalidate: the appearance changed; `layout()` sets the colors.
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // invalidate: another window can bring another theme scope and scale (`layout()` reads both).
        needsLayout = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true // invalidate: the scale changed; the opaque hairline is one device pixel.
    }

    /// Re-reads the material (Reduce Transparency) and the theme; the
    /// overlay calls it each time the hints show.
    public func refresh() { needsLayout = true } // invalidate: the hints show; material and theme are read again.

    /// The material this chip draws now.
    public var material: OverlayMaterial {
        OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                               reduceTransparency: reduceTransparency.isEnabled)
    }

    public override func layout() {
        super.layout()
        let radius = bounds.height / 2
        let opaque = material == .opaque
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        // Colors of the theme scope the chip sits in (room, workspace or terminal theme).
        performWithTheme {
            label.textColor = Palette.textPrimary
            if opaque {
                glass?.isHidden = true
                fill.isHidden = false
                fill.frame = bounds
                fill.layer?.cornerRadius = radius
                fill.layer?.backgroundColor = Palette.popupSurface.cgColor
                fill.layer?.borderColor = Palette.separator.cgColor
                fill.layer?.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
                layer?.shadowOpacity = 1
                layer?.shadowColor = Palette.shadow.withAlphaComponent(0.22).cgColor
                layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            } else {
                // Glass draws its own edge light; a layer shadow under it would darken the see-through center.
                let glass = self.glass ?? makeGlass()
                glass.isHidden = false
                glass.frame = bounds
                glass.cornerRadius = radius
                // The theme tint at 1.5 times its alpha: see-through, yet the 10 pt text keeps its contrast over bright content.
                let tint = Palette.glassTint
                glass.tintColor = tint.withAlphaComponent(min(tint.alphaComponent * 1.5, 1))
                fill.isHidden = true
                layer?.shadowOpacity = 0
                layer?.shadowPath = nil
            }
        }
    }

    private func makeGlass() -> GlassPanelView {
        let glass = GlassPanelView(style: .regular)
        glass.translatesAutoresizingMaskIntoConstraints = true
        addSubview(glass, positioned: .below, relativeTo: label)
        self.glass = glass
        return glass
    }
}
