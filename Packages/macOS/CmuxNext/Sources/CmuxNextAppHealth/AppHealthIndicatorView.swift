public import AppKit
public import CmuxNextControl
public import CmuxNextDesign

/// App health's entry at the sidebar's bottom-left (design/app-health.md): nothing while every part is
/// healthy and no action waits, nothing for a part that is only slow (the app is still answering, and the
/// next step, stuck, repairs it on its own), otherwise a dot and one line that names the part and what is
/// happening to it ("Agent chat isn't responding", "Reloading Agent chat…", "Agent chat needs a repair");
/// a click opens the popover, whose Repair now is the person's way out.
///
/// It never takes room from its neighbors (Leo, 2026-11-11: "slow indicator on the bottom left is
/// uselsss and layout shifts the space. it's bad"): the footer places it over the sidebar, never in the
/// footer row's flow, so the spaces strip, the update button and Search stay where they are when it comes
/// and goes. No motion: a new headline is drawn in one frame. It never fades with the footer.
@MainActor
public final class AppHealthIndicatorView: NSView, AvatarBadgePlacing {
    public enum Tone: Equatable { case danger, attention, muted }
    /// The gallery's treatments (AAAppHealthIndicatorGalleryTests, web `ui.app-health.footer-row`):
    /// `overlay`, the dot and its line on a small sidebar card (the sidebar cards' veil) floating above the footer row at the
    /// avatar's edge (shipped); `dot`, the dot alone as a badge on the avatar's corner, its line the tooltip;
    /// `hidden`, nothing at all (the popover still opens from the "Restoring sessions…" card's Details).
    public enum Style: CaseIterable { case overlay, dot, hidden }

    public var style = Style.overlay {
        didSet {
            guard style != oldValue else { return }
            label.isHidden = style != .overlay
            glass.isHidden = style != .overlay
            isHidden = style == .hidden || text.isEmpty
            applyColors()
            superview?.needsLayout = true
        }
    }

    /// Whether the footer badges the profile avatar's corner with it (`dot`) instead of floating it above
    /// the footer row. Either way it takes no room in the row.
    public var sitsOnAvatar: Bool { style == .dot }

    /// The press (the App opens ``AppHealthPopover``).
    public var onPress: (() -> Void)?
    public private(set) var text = ""
    public private(set) var tone = Tone.muted
    /// The overlay chip's surface: the sidebar cards' veil and rim over the sidebar's glass, never a solid
    /// fill or a second glass (design/surface-materials.md `sidebar-card`; Leo, 2026-10-21: "STOP DOING
    /// SOLID. WE HAVE GLASS, SO JUST USE GLASS.").
    private let glass = CardSurfaceView()
    /// The dot, on its own layer-backed view so it draws over the veil.
    private let dotView = NSView()
    private let dot = CALayer()
    private let label = ChromeLabel(labelWithString: "")
    static let dotSize: CGFloat = 6

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.translatesAutoresizingMaskIntoConstraints = true
        addSubview(glass)
        dotView.layer = dot
        dotView.wantsLayer = true
        addSubview(dotView)
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.sidebar.appHealth")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `headline` (nil: every part healthy, nothing waits; the view hides).
    public func show(_ headline: AppHealth.Headline?) {
        let line = headline.flatMap(AppHealthStrings.line)
        let tone = Self.tone(of: headline)
        let hidden = line == nil || style == .hidden
        guard line ?? "" != text || tone != self.tone || isHidden != hidden else { return }
        text = line ?? ""
        self.tone = tone
        label.stringValue = text
        setAccessibilityLabel(text)
        themedToolTip = text
        isHidden = hidden
        applyColors()
        // The footer places it over the sidebar again; nothing beside it moves.
        superview?.needsLayout = true
    }

    static func tone(of headline: AppHealth.Headline?) -> Tone {
        switch headline?.state {
        case .failed?, .stuck?: .danger
        case .repairing?, .slow?: .attention
        default: .muted
        }
    }

    private var inset: CGFloat { style == .overlay ? Metrics.space2 : 0 }

    override public var fittingSize: NSSize {
        // The dot badge: the dot and a ring of the sidebar's own color around it, so it reads on any avatar.
        if style == .dot { return NSSize(width: Self.dotSize + 2 * Metrics.space1, height: Self.dotSize + 2 * Metrics.space1) }
        let text = label.fittingSize
        return NSSize(width: inset * 2 + Self.dotSize + Metrics.space2 + text.width, height: max(text.height + 2 * Metrics.space1, Self.dotSize))
    }

    override public func layout() {
        super.layout()
        let size = Self.dotSize
        dotView.frame = CGRect(x: style == .dot ? (bounds.width - size) / 2 : inset, y: (bounds.height - size) / 2, width: size, height: size)
        dot.cornerRadius = size / 2
        glass.frame = bounds
        glass.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
        layer?.cornerRadius = style == .dot ? bounds.height / 2 : 0
        let x = inset + size + Metrics.space2
        let height = label.fittingSize.height
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - inset), height: height)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            // Over the list the chip is the card veil under it (`glass`); the badge rings the dot in the
            // sidebar's color so it separates from the avatar.
            layer?.backgroundColor = style == .dot ? Palette.sidebarBackground.cgColor : nil
            dot.backgroundColor = switch tone {
            case .danger: Palette.danger.cgColor
            case .attention: Palette.attention.cgColor
            case .muted: Palette.textTertiary.cgColor
            }
        }
    }

    /// The whole line takes the click, its label included. `point` is in the superview's coordinates
    /// (`NSView.hitTest(_:)`), which AppKit's own test converts; a hidden line takes none.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override public func mouseDown(with event: NSEvent) {}

    override public func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override public func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}
