import AppKit
import CmuxNextDesign

/// The Density Overlay Playground's small gray button (Capture, Controls…, the offset nudges): the AppKit twin of
/// Settings' `SettingsButtonStyle`, the theme's hover fill at rest and its selection fill while pressed, the title in
/// the body font and primary ink. The view sets ``tokens`` from `SettingsTheme` on every theme change.
final class DensityOverlayButton: ClickableButton {
    /// The title.
    private let label: String
    /// The colors it draws in (the Settings window's theme).
    var tokens: ThemeTokens { didSet { if tokens != oldValue { refresh() } } }

    init(title: String, tokens: ThemeTokens, target: AnyObject?, action: Selector) {
        self.tokens = tokens
        label = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel(title)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool { didSet { applyFill() } }

    override var intrinsicContentSize: NSSize {
        let size = (label as NSString).size(withAttributes: [.font: Typography.body])
        return NSSize(width: ceil(size.width) + 2 * Metrics.space4, height: ceil(size.height) + 2 * Metrics.space2)
    }

    /// Applies the fill, corner and title for the current tokens, metrics and press state.
    func refresh() {
        layer?.cornerRadius = Metrics.buttonCornerRadius
        applyFill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: Typography.body, .foregroundColor: tokens.textPrimary.nsColor, .paragraphStyle: paragraph,
        ])
        invalidateIntrinsicContentSize()
    }

    private func applyFill() {
        layer?.backgroundColor = (isHighlighted ? tokens.selectionFill : tokens.hoverFill).nsColor.cgColor
    }
}
