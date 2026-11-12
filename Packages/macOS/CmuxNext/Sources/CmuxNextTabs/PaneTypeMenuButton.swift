import AppKit
import CmuxNextDesign
import QuartzCore

/// The pane-type chooser (⌄) beside the tab bar's +.
///
/// The pane strip handles pointer events; accessibility invokes the same menu directly.
/// Keep NSButton's click simulation out of AXPress: a popup is open on press, not on release.
/// Its look follows ``TabTrailingButtons``: in every style but `plates` it draws its chevron as the +'s stroke (one
/// weight, one ink) and shows hover as the + does (Lawrence 2026-11-07: the square grey block behind it).
final class PaneTypeMenuButton: NSView {
    /// The `plates` look (before 2026-11-07): an SF Symbol on a rounded plate.
    private let glyph = TitlebarBandButton(symbol: "chevron.down")
    private let fillLayer = CALayer()
    private let chevronLayer = CAShapeLayer()
    private lazy var pointer = PointerHover(self) { [weak self] hovering in
        self?.updateColors()
        self?.onHoverChange?(hovering)
    }
    /// The pointer came onto (true) or left (false) the ⌄.
    var onHoverChange: ((Bool) -> Void)?
    /// The + beside it is under the pointer (the split look's shared hover).
    var siblingHovered = false {
        didSet { if oldValue != siblingHovered { updateColors() } }
    }
    var onPress: (() -> Void)?
    /// VoiceOver moved its focus onto (true) or off (false) the chooser.
    var onAccessibilityFocus: ((Bool) -> Void)?
    var isHighlighted = false {
        didSet {
            glyph.isHighlighted = isHighlighted
            glyph.hover.state.pressed = isHighlighted
            updateColors()
        }
    }
    /// The trailing controls' shared look.
    var style: TabTrailingButtons = TabTunables.trailingButtons.value {
        didSet {
            guard style != oldValue else { return }
            needsLayout = true
            updateColors()
        }
    }
    /// Whether the pointer is over it (the shared hover owner, ``PointerHover``).
    var isHovered: Bool { pointer.isHovering }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The add buttons' size class: the chevron spans about the +'s width beside it.
        glyph.symbolPointSize = { Metrics.addMenuChevronPointSize }
        layer?.masksToBounds = false
        fillLayer.cornerCurve = .circular
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        chevronLayer.fillColor = nil
        chevronLayer.lineCap = .round
        chevronLayer.lineJoin = .round
        chevronLayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(chevronLayer)
        addSubview(glyph)
        glyph.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(Strings.axNewTab)
        setAccessibilityIdentifier("cmux.tabs.newTabMenu")
        themedToolTip = Strings.axNewTab
        pointer.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let plates = style == .plates
        glyph.isHidden = !plates
        glyph.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevronLayer.isHidden = plates
        fillLayer.isHidden = plates
        let scale = window?.backingScaleFactor ?? 2
        chevronLayer.contentsScale = scale
        chevronLayer.frame = bounds
        // Circles: one diameter for the +, the ⌄ and the ⋮ (the +'s square side), centered on the glyph. Split: the
        // whole segment, with the group's trailing corners rounded (the + rounds the leading ones).
        let side = min(bounds.width, bounds.height)
        if style == .split {
            fillLayer.frame = bounds
            fillLayer.cornerRadius = NewTabButtonView.splitCornerRadius
            fillLayer.cornerCurve = Metrics.tabCornerCurve
            fillLayer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        } else {
            fillLayer.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            fillLayer.cornerRadius = side / 2
            fillLayer.maskedCorners = NewTabButtonView.allCorners
        }
        // The split look's ⌄ leans half a step toward its + (NewTabButtonView leans the + back).
        let lean = style == .split ? Metrics.space1 / 2 : 0
        let center = CGPoint(x: ((bounds.midX - lean) * scale).rounded() / scale, y: (bounds.midY * scale).rounded() / scale)
        let half = NewTabButtonView.chevronHalfWidth, rise = NewTabButtonView.chevronRise
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - half, y: center.y - rise / 2))
        path.addLine(to: CGPoint(x: center.x, y: center.y + rise / 2))
        path.addLine(to: CGPoint(x: center.x + half, y: center.y - rise / 2))
        chevronLayer.path = path
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func updateColors() {
        let hovering = pointer.isHovering, pressed = isHighlighted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            chevronLayer.strokeColor = NewTabButtonView.glyphInk(hovering: hovering, pressed: pressed).cgColor
            chevronLayer.lineWidth = NewTabButtonView.glyphLineWidth(pressed: pressed)
            switch style {
            case .circles: fillLayer.backgroundColor = ChromeHover.fillColor(.init(hovering: hovering, pressed: pressed))?.cgColor
            case .split:
                fillLayer.backgroundColor = NewTabButtonView.splitFill(hovering: hovering, pressed: pressed, siblingHovered: siblingHovered)?.cgColor
            case .plates, .glyphs, .merged: fillLayer.backgroundColor = nil
            }
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        onAccessibilityFocus?(accessibilityFocused)
    }
}
