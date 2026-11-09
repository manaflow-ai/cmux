public import AppKit
public import CmuxNextControl
import CmuxNextDesign

/// App health's entry on the sidebar's footer line (design/app-health.md, treatment A): nothing while
/// every part is healthy and no action waits; otherwise a dot and one plain line ("Session service: Not
/// responding"), and a click opens the popover. The dot is danger for a part that needs the person,
/// attention while the app repairs it or it is slow, muted for a queued action alone. No motion: a new
/// headline is drawn in one frame, and the sidebar places the line again (it shows or hides as one).
/// It never fades with the footer: it is the one thing on the line the person must see.
@MainActor
public final class AppHealthIndicatorView: NSView {
    public enum Tone: Equatable { case danger, attention, muted }
    /// The gallery's treatments (AAAppHealthIndicatorGalleryTests): `line`, the dot and its line (shipped);
    /// `chip`, the same on the live mode mark's hover gray; `dot`, the dot alone with the line as its tooltip.
    public enum Style: CaseIterable { case line, chip, dot }

    public var style = Style.line {
        didSet { if style != oldValue { label.isHidden = style == .dot; applyColors(); superview?.needsLayout = true } }
    }

    /// The press (the App opens ``AppHealthPopover``).
    public var onPress: (() -> Void)?
    public private(set) var text = ""
    public private(set) var tone = Tone.muted
    private let dot = CALayer()
    private let label = ChromeLabel(labelWithString: "")
    static let dotSize: CGFloat = 6

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
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
        guard line ?? "" != text || tone != self.tone || isHidden != (line == nil) else { return }
        text = line ?? ""
        self.tone = tone
        label.stringValue = text
        setAccessibilityLabel(text)
        themedToolTip = text
        isHidden = line == nil
        applyColors()
        // The footer line makes room for it, or gives the room back.
        superview?.needsLayout = true
    }

    static func tone(of headline: AppHealth.Headline?) -> Tone {
        switch headline?.state {
        case .failed?, .stuck?: .danger
        case .repairing?, .slow?: .attention
        default: .muted
        }
    }

    private var inset: CGFloat { style == .chip ? Metrics.space2 : 0 }

    override public var fittingSize: NSSize {
        let text = label.fittingSize
        if style == .dot { return NSSize(width: Self.dotSize * 3, height: max(text.height, Self.dotSize)) }
        return NSSize(width: inset * 2 + Self.dotSize + Metrics.space1 + text.width, height: max(text.height + (style == .chip ? 4 : 0), Self.dotSize))
    }

    override public func layout() {
        super.layout()
        let size = Self.dotSize
        dot.frame = CGRect(x: style == .dot ? (bounds.width - size) / 2 : inset, y: (bounds.height - size) / 2, width: size, height: size)
        dot.cornerRadius = size / 2
        layer?.cornerRadius = style == .chip ? Metrics.chipCornerRadius(height: bounds.height) : 0
        let x = inset + size + Metrics.space1
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
            layer?.backgroundColor = style == .chip ? Palette.hoverFill.cgColor : nil
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
