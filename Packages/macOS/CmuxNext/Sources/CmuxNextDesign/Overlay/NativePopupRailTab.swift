import AppKit
import CmuxAgentBrands
import CmuxNextIcons

/// One rail tab as the web picker's harness placements draw it (modelPicker.css
/// `.acpmux-quick-rail-tab`): its mark (an agent mark, a text mark, or an icon) and, outside the
/// symbols row, its name. Muted at rest; the hovered, highlighted and checked tab takes the rounded
/// wash and the text colour; in the symbols row the checked tab also gets the accent bar under it.
/// The page decides every word and mark; this view only draws them.
@MainActor
final class NativePopupRailTab: NSView {
    static let markSize: CGFloat = 16

    let row: NativePopupRow
    let placement: NativePopupRailPlacement
    var onActivate: (() -> Void)?
    var onHover: (() -> Void)?
    /// The keyboard's highlight (Add harness reached with Left and Right).
    var isHighlighted = false { didSet { if oldValue != isHighlighted { restyle() } } }
    var isEnabled: Bool { row.disabled != true }
    var isSelected: Bool { row.checked == true }

    let markView: NSView?
    let nameLabel: ThemedLabel?
    private var isHovering = false { didSet { if oldValue != isHovering { restyle() } } }
    private var tracking: NSTrackingArea?

    init(row: NativePopupRow, placement: NativePopupRailPlacement) {
        self.row = row
        self.placement = placement
        markView = Self.makeMark(row)
        if placement == .symbols {
            nameLabel = nil
        } else {
            let label = ThemedLabel(wrappingLabelWithString: row.label)
            label.font = placement == .compact ? Typography.caption : Typography.body
            label.alignment = placement == .compact ? .center : .natural
            label.lineBreakMode = placement == .top ? .byTruncatingTail : .byWordWrapping
            label.maximumNumberOfLines = placement == .top ? 1 : 0
            nameLabel = label
        }
        super.init(frame: NSRect(x: 0, y: 0, width: PopupStyle.standard.rowHeight, height: PopupStyle.standard.rowHeight))
        for view in [markView, nameLabel].compactMap(\.self) { addSubview(view) }
        // The name is the tab's title on hover and its accessible name (never dropped, even when
        // the symbols row shows only the mark).
        themedToolTip = row.description.map { "\(row.label) · \($0)" } ?? row.label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.label)
        setAccessibilityIdentifier(row.id)
        setAccessibilityEnabled(isEnabled)
        setAccessibilitySelected(isSelected)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Marks

    private static func makeMark(_ row: NativePopupRow) -> NSView? {
        if let mark = row.mark, AgentBrandCatalog.spec(forAgent: mark) != nil {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityElement(false)
            return view
        }
        if let text = row.monogram {
            // A harness with no symbol: its initial in a hairline box, one colour like the symbols.
            let label = NativePopupMonogram(text: text)
            label.setAccessibilityElement(false)
            return label
        }
        if let icon = row.icon {
            let view = NSImageView(image: NSImage.icon(IconName(icon), size: markSize))
            view.setAccessibilityElement(false)
            return view
        }
        return nil
    }

    /// The symbols row draws each mark in the theme's text colour (AgentMark `tint`); the named
    /// placements keep the brand's own colours, as the web tabs do.
    private func markImage() -> NSImage? {
        guard let mark = row.mark else { return nil }
        if placement == .symbols {
            guard let brand = AgentBrandCatalog.brand(for: mark)?.rawValue else { return nil }
            return AgentBrandCatalog.templateImage(brand: brand, size: Self.markSize)
        }
        guard let spec = AgentBrandCatalog.spec(forAgent: mark, pointSize: Double(Self.markSize)) else { return nil }
        let image = NSImage(size: NSSize(width: Self.markSize, height: Self.markSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            AgentBrandRenderer.draw(spec, in: context, rect: rect.insetBy(dx: 1, dy: 1), style: .brand, dark: dark,
                                    monoColor: CGColor(gray: 0, alpha: 1), flipped: false)
            return true
        }
        image.accessibilityDescription = row.label
        return image
    }

    var isLit: Bool { isEnabled && (isSelected || isHovering || isHighlighted) }

    private func restyle() {
        let lit = isLit
        performWithTheme {
            let ink = isEnabled ? (lit ? Palette.textPrimary : Palette.textSecondary) : Palette.textTertiary
            if let image = markView as? NSImageView {
                if row.mark != nil, image.image == nil { image.image = markImage() }
                image.contentTintColor = image.image?.isTemplate == true ? ink : nil
                image.alphaValue = isEnabled ? 1 : 0.5
            }
            (markView as? NativePopupMonogram)?.ink = isEnabled ? (lit ? .primary : .secondary) : .tertiary
            nameLabel?.ink = isEnabled ? (lit ? .primary : .secondary) : .tertiary
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: Size

    /// The tab's size for a strip of `available` points (symbols, top) or a column that wide
    /// (left, compact).
    func preferredSize(available: CGFloat) -> NSSize {
        let height = PopupStyle.standard.rowHeight
        let pad = Metrics.space2
        let mark: CGFloat = markView == nil ? 0 : Self.markSize
        switch placement {
        case .symbols:
            return NSSize(width: height, height: height)
        case .top:
            let text = ceil(nameLabel?.naturalSize.width ?? 0)
            let width = pad + mark + (mark > 0 ? pad : 0) + text + pad
            return NSSize(width: min(available, width), height: height)
        case .left:
            let textWidth = max(0, available - pad * 2 - (mark > 0 ? mark + pad : 0))
            let text = textHeight(width: textWidth)
            return NSSize(width: available, height: max(height, text + Metrics.space1 * 2))
        case .compact:
            let text = textHeight(width: max(0, available - Metrics.space1 * 2))
            return NSSize(width: available, height: Metrics.space1 * 2 + mark + text)
        }
    }

    private func textHeight(width: CGFloat) -> CGFloat {
        guard let nameLabel else { return 0 }
        nameLabel.preferredMaxLayoutWidth = width
        return ceil(nameLabel.size(forWidth: width).height)
    }

    override func layout() {
        super.layout()
        let pad = Metrics.space2
        let side = Self.markSize
        switch placement {
        case .symbols:
            markView?.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        case .top, .left:
            var x = pad
            if let markView {
                markView.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
                x += side + pad
            }
            let width = max(0, bounds.width - x - pad)
            let height = min(bounds.height, placement == .top ? ceil(nameLabel?.naturalSize.height ?? 0) : textHeight(width: width))
            nameLabel?.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        case .compact:
            var y = Metrics.space1
            if let markView {
                markView.frame = NSRect(x: (bounds.width - side) / 2, y: y, width: side, height: side)
                y += side
            }
            let width = max(0, bounds.width - Metrics.space1 * 2)
            nameLabel?.frame = NSRect(x: Metrics.space1, y: y, width: width, height: textHeight(width: width))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isLit else { return }
        let radius = PopupStyle.standard.rowCornerRadius
        performWithTheme {
            Palette.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            // The symbols row's accent bar under the checked mark: half the tab wide, half a grid step tall.
            guard placement == .symbols, isSelected else { return }
            let bar = NSRect(x: bounds.width / 4, y: bounds.maxY - Metrics.space1 / 2, width: bounds.width / 2, height: Metrics.space1 / 2)
            Palette.accentFill.setFill()
            NSBezierPath(roundedRect: bar, xRadius: Metrics.capsuleRadius(bar.size), yRadius: Metrics.capsuleRadius(bar.size)).fill()
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if isEnabled { onHover?() }
    }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate?()
        return true
    }
}

/// A harness's text mark in the symbols row: its initial in a 16 pt hairline box.
@MainActor
final class NativePopupMonogram: NSView {
    let label: ThemedLabel
    var ink: ThemeInk = .secondary { didSet { label.ink = ink; needsDisplay = true } }

    init(text: String) {
        label = ThemedLabel(labelWithString: text)
        label.font = Typography.system(size: Typography.caption.pointSize, weight: .semibold)
        label.alignment = .center
        label.ink = .secondary
        super.init(frame: NSRect(x: 0, y: 0, width: NativePopupRailTab.markSize, height: NativePopupRailTab.markSize))
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = ceil(label.naturalSize.height)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = Metrics.lineWidth(0.5)
        guard width > 0 else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: Metrics.controlCornerRadius, yRadius: Metrics.controlCornerRadius)
        path.lineWidth = width
        performWithTheme {
            (ink == .primary ? Palette.textPrimary : ink == .secondary ? Palette.textSecondary : Palette.textTertiary).setStroke()
            path.stroke()
        }
    }
}
