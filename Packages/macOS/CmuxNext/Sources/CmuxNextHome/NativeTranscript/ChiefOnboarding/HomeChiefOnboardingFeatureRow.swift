import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One line of what Chief does or what can come later on Meet Chief's card: a glyph, a short title and one
/// sentence under it. Information only: it takes no click.
final class HomeChiefOnboardingFeatureRow: NSView {
    let glyph = NSImageView()
    let title: ChromeLabel
    let detail: ChromeLabel
    let icon: IconName
    private var scale: CGFloat = 1

    static let glyphGap: CGFloat = 10
    static let titleGap: CGFloat = 1

    init(icon: IconName, title: String, detail: String) {
        self.icon = icon
        self.title = ChromeLabel(labelWithString: title)
        self.detail = ChromeLabel(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        self.title.isSelectable = false
        self.title.lineBreakMode = .byTruncatingTail
        self.detail.isSelectable = false
        self.detail.maximumNumberOfLines = 0
        for view in [glyph, self.title, self.detail] as [NSView] { addSubview(view) }
        // VoiceOver reads the row as one line: its title, then its sentence.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title). \(detail)")
        applyScale(1)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    private var glyphSide: CGFloat { .iconRowSize(forLabelPointSize: 15 * scale) }

    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        glyph.image = NSImage.icon(icon, size: glyphSide)
        title.font = .systemFont(ofSize: TypeScale.Base.body * scale, weight: TypeScale.emphasis)
        detail.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor, glyph tint: NSColor) { // theme-scoped
        title.textColor = primary
        detail.textColor = secondary
        glyph.contentTintColor = tint
    }

    private var textX: CGFloat { glyphSide + Self.glyphGap * scale }

    /// The row's height in a column `width` wide.
    func height(for width: CGFloat) -> CGFloat {
        let inner = max(0, width - textX)
        return ceil(title.intrinsicContentSize.height) + Self.titleGap * scale + ceil(detail.size(forWidth: inner).height)
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - textX)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        // The glyph centres on the title's line, not on the whole row.
        glyph.frame = CGRect(x: 0, y: (titleHeight - glyphSide) / 2, width: glyphSide, height: glyphSide)
        title.frame = CGRect(x: textX, y: 0, width: inner, height: titleHeight)
        let detailHeight = ceil(detail.size(forWidth: inner).height)
        detail.frame = CGRect(x: textX, y: title.frame.maxY + Self.titleGap * scale, width: inner, height: detailHeight)
    }
}
