import CmuxAgentBrands
import AppKit
import CmuxNextDesign

/// Shortcut badges drawn directly (no subviews): one rounded gray cap per key.
final class PaletteKeycapsView: NSView {
    var keycaps: [String] = [] {
        didSet {
            guard keycaps != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    nonisolated override var isFlipped: Bool { true }

    /// theme-scoped: read inside `performWithTheme` (draw) or for measuring.
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Typography.shortcut, .foregroundColor: Palette.textSecondary]
    }

    private func capWidth(_ cap: String) -> CGFloat {
        let text = (cap as NSString).size(withAttributes: attributes).width
        return max(PaletteLayout.keycapSize, ceil(text) + Metrics.space2 * 2)
    }

    override var intrinsicContentSize: NSSize {
        guard !keycaps.isEmpty else { return .zero }
        let widths = keycaps.map(capWidth)
        return NSSize(width: widths.reduce(0, +) + Metrics.space1 * CGFloat(keycaps.count - 1), height: PaletteLayout.keycapSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let size = PaletteLayout.keycapSize
        let y = (bounds.height - size) / 2
        performWithTheme {
            for cap in keycaps {
                let width = capWidth(cap)
                let rect = NSRect(x: x, y: y, width: width, height: size)
                Palette.hoverFill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: PaletteLayout.keycapCornerRadius, yRadius: PaletteLayout.keycapCornerRadius).fill()
                let text = cap as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
                x += width + Metrics.space1
            }
        }
    }
}

/// Row background: a rounded gray fill for selection and hover, never the
/// system accent. A fill layer under the cell, so a hover eases in and
/// clears at once (`ChromeHover.fade`); selection, reuse and redraws paint
/// at once.
final class PaletteTableRowView: NSTableRowView {
    private let fill = CALayer()
    private var fadesNextFill = false

    override func prepareForReuse() {
        super.prepareForReuse()
        // A fade asked for before the row was reused belongs to its old row.
        fadesNextFill = false
    }

    var isPaletteSelected = false {
        didSet { if isPaletteSelected != oldValue { needsDisplay = true } }
    }

    /// The table's selection only tells VoiceOver which row is selected (`syncTableSelection`);
    /// the row's text keeps its own colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.cornerRadius = PaletteLayout.rowCornerRadius
        fill.cornerCurve = .continuous
        fill.actions = ["bounds": NSNull(), "position": NSNull()]
        fill.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.insertSublayer(fill, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A pointer hover change; `animated` fades it.
    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }
        fadesNextFill = animated
        isHovered = hovered
    }

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: PaletteLayout.listInset, dy: 0)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        performWithTheme {
            let color = isPaletteSelected ? Palette.selectionFill : isHovered ? Palette.hoverFill : nil
            ChromeHover.paint(fill, color, animated: fadesNextFill && window != nil)
        }
        fadesNextFill = false
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// One reusable result row: icon, highlighted title, subtitle, accessory,
/// keycaps. Laid out by hand; configured, never rebuilt.
final class PaletteRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("palette.row")

    private let icon = NSImageView()
    let swatch = PaletteSwatchView()
    private let title = PaletteText.label(Typography.body, tone: nil)
    private let subtitle = PaletteText.label(Typography.caption, tone: .secondary)
    private let accessory = PaletteText.label(Typography.caption, tone: .tertiary)
    private let keycaps = PaletteKeycapsView()
    private var symbolName: String?
    private var titleText = ""
    private var titleFace: NSFont?
    private var highlights: [Int] = []
    private var isSelected = false
    private var swatches: [ThemeRGB] = []
    private var ball: PaletteBall?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyDown
        subtitle.lineBreakMode = .byTruncatingMiddle
        [icon, swatch, title, subtitle, accessory, keycaps].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: PaletteRow, isSelected: Bool) {
        let item = row.item
        let iconKey = item.image.map { "image:\(ObjectIdentifier($0).hashValue)" } ?? item.brand.map { "brand:\($0)" } ?? item.symbol
        if symbolName != iconKey {
            symbolName = iconKey
            // A page's favicon draws as is; an agent row draws its brand mark as a template,
            // tinted like the symbols.
            icon.image = item.image.map { NSImage(cgImage: $0, size: NSSize(width: Metrics.iconSize, height: Metrics.iconSize)) }
                ?? item.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: Metrics.iconSize) }
                ?? PaletteText.symbol(item.symbol ?? "command", size: Metrics.iconSize)
        }
        swatches = item.swatches
        ball = item.ball
        let drawsColor = !item.swatches.isEmpty || item.ball != nil
        swatch.isHidden = !drawsColor
        icon.isHidden = drawsColor
        self.isSelected = isSelected
        titleText = item.title
        titleFace = item.fontFamily.flatMap { PaletteFontFaces.shared.font(family: $0, size: Typography.body.pointSize) }
        highlights = row.highlights
        applyColors()
        // A reused cell can come from before a text size change.
        subtitle.refreshFont()
        accessory.refreshFont()
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        accessory.stringValue = item.accessory ?? ""
        accessory.isHidden = item.accessory == nil
        keycaps.keycaps = item.keycaps ?? []
        keycaps.needsDisplay = true
        keycaps.isHidden = item.keycaps == nil
        alphaValue = item.isEnabled ? 1 : 0.45
        setAccessibilityLabel(item.title)
        needsLayout = true
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        performWithTheme { icon.contentTintColor = selected ? Palette.textPrimary : Palette.textSecondary }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = isSelected ? Palette.textPrimary : Palette.textSecondary
            title.attributedStringValue = Self.highlighted(titleText, highlights, face: titleFace)
            swatch.colors = ball.map { [$0.color.ballRGB] } ?? swatches
        }
    }

    override func layout() {
        super.layout()
        let padding = PaletteLayout.listInset + Metrics.space4
        let midY = bounds.midY
        let box = PaletteLayout.iconBox
        icon.frame = NSRect(x: padding, y: midY - box / 2, width: box, height: box)
        swatch.frame = icon.frame.insetBy(dx: 1, dy: 1)
        var right = bounds.maxX - padding
        if !keycaps.isHidden {
            let size = keycaps.intrinsicContentSize
            right -= size.width
            keycaps.frame = pixelAligned(NSRect(x: right, y: midY - size.height / 2, width: size.width, height: size.height))
            right -= Metrics.space4
        }
        if !accessory.isHidden {
            let width = min(PaletteText.fittingWidth(accessory), bounds.width / 4)
            right -= width
            accessory.frame = centered(x: right, width: width, field: accessory)
            right -= Metrics.space4
        }
        let left = icon.frame.maxX + Metrics.space4
        let available = max(0, right - left)
        let titleWidth = min(PaletteText.fittingWidth(title), available)
        title.frame = centered(x: left, width: titleWidth, field: title)
        if !subtitle.isHidden {
            let x = title.frame.maxX + Metrics.space3
            subtitle.frame = centered(x: x, width: max(0, right - x), field: subtitle)
        }
    }

    private func centered(x: CGFloat, width: CGFloat, field: NSTextField) -> NSRect {
        let height = PaletteText.height(field)
        return pixelAligned(NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height))
    }

    /// Matched characters in full label color and the emphasized weight; the
    /// rest slightly muted, so the match reads without a colored highlight.
    /// theme-scoped: called inside `performWithTheme`.
    /// `face` (a font row's own family) draws every character, the match by color alone.
    static func highlighted(_ text: String, _ positions: [Int], face: NSFont? = nil) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: face ?? Typography.body,
            .foregroundColor: positions.isEmpty ? Palette.textPrimary : Palette.textPrimary.withAlphaComponent(0.78),
        ]
        let result = NSMutableAttributedString(string: text, attributes: base)
        guard !positions.isEmpty else { return result }
        let emphasized: [NSAttributedString.Key: Any] = [.font: face ?? Typography.bodyEmphasized, .foregroundColor: Palette.textPrimary]
        let wanted = Set(positions)
        var utf16Offset = 0
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            let length = scalar.utf16.count
            if wanted.contains(offset) {
                result.addAttributes(emphasized, range: NSRange(location: utf16Offset, length: length))
            }
            utf16Offset += length
        }
        return result
    }
}
