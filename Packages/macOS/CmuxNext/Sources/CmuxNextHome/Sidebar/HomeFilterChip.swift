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

    init(title: String, metrics: HomeSidebarHeaderMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        imagePosition = .imageTrailing
        imageHugsTitle = true
        setAccessibilityIdentifier("cmux.home.sidebar.filterChip")
        setAccessibilityHelp(HomeConversationStrings.filterChipHelp)
        wantsLayer = true
        applyMetrics()
    }

    /// The text and the xmark at ``metrics``, then the tint over the new font.
    private func applyMetrics() {
        font = Typography.system(size: metrics.chipFontSize, weight: TypeScale.emphasis)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: metrics.chipGlyphSize, weight: TypeScale.emphasis))
        invalidateIntrinsicContentSize()
        applyTint()
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
        layer?.cornerRadius = bounds.height / 2
    }

    /// The accent text and fill in the view's theme scope (also on a theme or appearance change).
    func applyTint() {
        let accent = performWithTheme { Palette.litGlyph }
        contentTintColor = accent
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: accent, .font: font ?? Typography.system(size: metrics.chipFontSize, weight: TypeScale.emphasis)])
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
