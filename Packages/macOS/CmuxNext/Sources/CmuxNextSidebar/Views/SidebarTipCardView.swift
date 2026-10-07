import AppKit
import CmuxNextDesign

/// The "Did you know" card above the footer (BOTTOM-LEFT-CARDS K1), in the
/// update card's slot and style (theme surface, hairline border): "Did you
/// know?", the feature, its one-line benefit, a quiet "Try It" button with
/// the feature's shortcut beside it, and an x that hides this tip for good.
/// Hidden without a tip.
final class SidebarTipCardView: NSView {
    var onTry: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    private(set) var tip: SidebarTipCard?
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let benefitLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    let tryButton = SidebarUpdateButton()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { 9 }, label: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        for label in [eyebrowLabel, titleLabel, shortcutLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        benefitLabel.maximumNumberOfLines = 2
        benefitLabel.lineBreakMode = .byWordWrapping
        benefitLabel.cell?.truncatesLastVisibleLine = true
        benefitLabel.isSelectable = false
        shortcutLabel.alignment = .right
        tryButton.isQuiet = true
        tryButton.onPress = { [weak self] in if let id = self?.tip?.id { self?.onTry?(id) } }
        closeButton.onPress = { [weak self] in if let id = self?.tip?.id { self?.onDismiss?(id) } }
        [eyebrowLabel, titleLabel, benefitLabel, shortcutLabel, tryButton, closeButton].forEach(addSubview)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `tip`, or hides the view for nil.
    func configure(_ tip: SidebarTipCard?) {
        guard tip != self.tip else { return }
        self.tip = tip
        isHidden = true  // red: K1 not implemented
        guard let tip, tip.id.isEmpty else { return }
        eyebrowLabel.stringValue = tip.eyebrow
        titleLabel.stringValue = tip.title
        benefitLabel.stringValue = tip.benefit
        shortcutLabel.stringValue = tip.shortcut ?? ""
        shortcutLabel.isHidden = tip.shortcut == nil
        tryButton.configure(title: tip.tryTitle, enabled: true, help: [tip.title, tip.benefit].joined(separator: ". "))
        closeButton.label = tip.dismissLabel
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space3 }
    private static var lineHeight: (caption: CGFloat, body: CGFloat) {
        (ceil(Typography.caption.boundingRectForFont.height), ceil(Typography.bodyEmphasized.boundingRectForFont.height))
    }

    /// Fixed: eyebrow, title, two benefit lines, the button row.
    static var height: CGFloat {
        let line = lineHeight
        return ceil(padding + line.caption + line.body + Metrics.space1 + 2 * line.caption + Metrics.space2
            + SidebarUpdateButton.height + padding)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding, line = Self.lineHeight
        layer?.cornerRadius = Metrics.space3
        eyebrowLabel.font = Typography.caption
        titleLabel.font = Typography.bodyEmphasized
        benefitLabel.font = Typography.caption
        shortcutLabel.font = Typography.caption
        let close: CGFloat = 16
        closeButton.frame = NSRect(x: b.width - pad / 2 - close, y: pad / 2, width: close, height: close)
        let width = max(0, b.width - 2 * pad)
        eyebrowLabel.frame = NSRect(x: pad, y: pad, width: max(0, width - close), height: line.caption)
        titleLabel.frame = NSRect(x: pad, y: eyebrowLabel.frame.maxY, width: width, height: line.body)
        benefitLabel.preferredMaxLayoutWidth = width
        benefitLabel.frame = NSRect(x: pad, y: titleLabel.frame.maxY + Metrics.space1, width: width, height: 2 * line.caption)
        let rowY = b.height - pad - SidebarUpdateButton.height
        let tryWidth = min(width, ceil(((tip?.tryTitle ?? "") as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
            + 2 * Metrics.space4)
        tryButton.frame = NSRect(x: pad, y: rowY, width: tryWidth, height: SidebarUpdateButton.height)
        let shortcutX = tryButton.frame.maxX + Metrics.space2
        shortcutLabel.frame = NSRect(x: shortcutX, y: rowY + (SidebarUpdateButton.height - line.caption) / 2,
                                     width: max(0, b.width - pad - shortcutX), height: line.caption)
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            eyebrowLabel.textColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            benefitLabel.textColor = Palette.textSecondary
            shortcutLabel.textColor = Palette.textTertiary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Tests

    /// Every line as shown, top to bottom.
    var shownText: [String] {
        [eyebrowLabel, titleLabel, benefitLabel].map(\.stringValue) + [tryButton.title] + (shortcutLabel.isHidden ? [] : [shortcutLabel.stringValue])
    }
}
