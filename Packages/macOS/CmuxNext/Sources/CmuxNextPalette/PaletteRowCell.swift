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

    override var isFlipped: Bool { true }

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
/// system accent.
final class PaletteTableRowView: NSTableRowView {
    var isPaletteSelected = false {
        didSet { if isPaletteSelected != oldValue { needsDisplay = true } }
    }

    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isPaletteSelected || isHovered else { return }
        performWithTheme {
            (isPaletteSelected ? Palette.selectionFill : Palette.hoverFill).setFill()
            let rect = bounds.insetBy(dx: PaletteLayout.listInset, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: PaletteLayout.rowCornerRadius, yRadius: PaletteLayout.rowCornerRadius).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// One reusable result row: icon, highlighted title, subtitle, accessory,
/// keycaps. Laid out by hand; configured, never rebuilt.
final class PaletteRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("palette.row")

    private let icon = NSImageView()
    private let title = PaletteText.label(Typography.body, tone: nil)
    private let subtitle = PaletteText.label(Typography.caption, tone: .secondary)
    private let accessory = PaletteText.label(Typography.caption, tone: .tertiary)
    private let keycaps = PaletteKeycapsView()
    private var symbolName: String?
    private var titleText = ""
    private var highlights: [Int] = []
    private var isSelected = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyDown
        subtitle.lineBreakMode = .byTruncatingMiddle
        [icon, title, subtitle, accessory, keycaps].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: PaletteRow, isSelected: Bool) {
        let item = row.item
        let iconKey = item.brand.map { "brand:\($0)" } ?? item.symbol
        if symbolName != iconKey {
            symbolName = iconKey
            // An agent row draws its brand mark as a template, tinted like the symbols.
            icon.image = item.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: Metrics.iconSize) }
                ?? PaletteText.symbol(item.symbol ?? "command", size: Metrics.iconSize)
        }
        self.isSelected = isSelected
        titleText = item.title
        highlights = row.highlights
        applyColors()
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        accessory.stringValue = item.accessory ?? ""
        accessory.isHidden = item.accessory == nil
        keycaps.keycaps = item.keycaps ?? []
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
            title.attributedStringValue = Self.highlighted(titleText, highlights)
        }
    }

    override func layout() {
        super.layout()
        let padding = PaletteLayout.listInset + Metrics.space4
        let midY = bounds.midY
        let box = PaletteLayout.iconBox
        icon.frame = NSRect(x: padding, y: midY - box / 2, width: box, height: box)
        var right = bounds.maxX - padding
        if !keycaps.isHidden {
            let size = keycaps.intrinsicContentSize
            right -= size.width
            keycaps.frame = NSRect(x: right, y: midY - size.height / 2, width: size.width, height: size.height)
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
        let height = field.intrinsicContentSize.height
        return NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// Matched characters in full label color and the emphasized weight; the
    /// rest slightly muted, so the match reads without a colored highlight.
    /// theme-scoped: called inside `performWithTheme`.
    static func highlighted(_ text: String, _ positions: [Int]) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: Typography.body,
            .foregroundColor: positions.isEmpty ? Palette.textPrimary : Palette.textPrimary.withAlphaComponent(0.78),
        ]
        let result = NSMutableAttributedString(string: text, attributes: base)
        guard !positions.isEmpty else { return result }
        let emphasized: [NSAttributedString.Key: Any] = [.font: Typography.bodyEmphasized, .foregroundColor: Palette.textPrimary]
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
