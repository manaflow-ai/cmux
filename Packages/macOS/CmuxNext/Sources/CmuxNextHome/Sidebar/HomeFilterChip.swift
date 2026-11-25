import AppKit
import CmuxNextDesign

/// The Home list's on filter, as a chip under its search row: "Unread ×" (the user, 2026-11-03,
/// msg 20156: a click on the filter button left the list at No Results with nothing showing that a
/// filter was on). A click turns the filter off. The theme's accent at a low alpha behind the
/// accent text; the header (`HomeSidebarView`) shows it only while the filter is on.
final class HomeFilterChip: ClickableButton {
    /// The chip's sizes at the sidebar's density and text size (``HomeSidebarHeaderMetrics``): its
    /// height, side padding, text size and xmark. The header sets them again on a change.
    var metrics: HomeSidebarHeaderMetrics {
        didSet {
            guard metrics != oldValue else { return }
            applyMetrics()
        }
    }

    /// The chip's words ("Unread"): the drawn title is them and the xmark.
    let label: String

    init(title: String, metrics: HomeSidebarHeaderMetrics) {
        self.metrics = metrics
        label = title
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        isBordered = false
        imagePosition = .noImage
        setAccessibilityIdentifier("cmux.home.sidebar.filterChip")
        setAccessibilityHelp(HomeConversationStrings.filterChipHelp)
        wantsLayer = true
        applyMetrics()
    }

    /// The text at ``metrics``, then the tint (and the xmark) over the new font.
    private func applyMetrics() {
        font = Typography.system(size: metrics.chipFontSize, weight: TypeScale.emphasis)
        invalidateIntrinsicContentSize()
        applyTint()
    }

    /// The kern after the text: the text's and the symbol's side bearings make it the 5 pt ink gap
    /// AppKit's trailing image gave (measured at 2x).
    static let xmarkKern: CGFloat = 3

    /// The xmark after the text, in the text: centred on the capitals' height (the user,
    /// 2026-11-23: "align this x"; as AppKit's trailing image it sat 1.25 pt low, on no line of
    /// the text). Tinted in the accent, as the text.
    private func xmark(_ accent: NSColor, font: NSFont) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: metrics.chipGlyphSize, weight: TypeScale.emphasis)
            .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
        guard let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return NSAttributedString()
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        // The symbol's ink is its alignment rect, not its whole image: that rect's middle on the
        // capitals' middle, on the 2x pixel grid.
        let ink = image.alignmentRect
        let y = font.capHeight / 2 - ink.midY
        attachment.bounds = CGRect(x: 0, y: (y * 2).rounded() / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: (size.width + 2 * metrics.chipPadding).rounded(.up), height: metrics.chipHeight)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: bounds.size)
    }

    /// The accent text and fill in the view's theme scope (also on a theme or appearance change).
    func applyTint() {
        let accent = performWithTheme { Palette.litGlyph }
        contentTintColor = accent
        let font = font ?? Typography.system(size: metrics.chipFontSize, weight: TypeScale.emphasis)
        let text = NSMutableAttributedString(string: label, attributes: [.foregroundColor: accent, .font: font])
        if text.length > 0 { text.addAttribute(.kern, value: Self.xmarkKern, range: NSRange(location: text.length - 1, length: 1)) }
        text.append(xmark(accent, font: font))
        attributedTitle = text
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        applyTint()
    }
}
