import AppKit

/// One grouped section of the Chief Settings panel: a small section title
/// over a rounded card (System Settings' grouped form, sized for a 280 pt
/// side panel). Rows stack inside the card, label over control, because the
/// panel is too narrow for label-beside-control rows.
@MainActor
final class ChiefSettingsCard: NSStackView {
    /// The section title above the card (11 pt semibold, secondary).
    let titleLabel: NSTextField
    /// The rounded box that holds the rows.
    let box = NSStackView()
    /// 13 pt row labels (primary text).
    private(set) var labels: [NSTextField] = []
    /// 11 pt captions under controls (secondary text).
    private(set) var captions: [NSTextField] = []
    let contentWidth: CGFloat

    /// - Parameters:
    ///   - title: The section title.
    ///   - width: The card's outer width.
    ///   - padding: The card's inner padding.
    init(title: String, width: CGFloat, padding: CGFloat) {
        titleLabel = NSTextField(labelWithString: title)
        contentWidth = width - 2 * padding
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        addArrangedSubview(titleLabel)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(title)
        addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A 13 pt label over `control`, linked as its accessibility title.
    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSTextField {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        labels.append(title)
        box.addArrangedSubview(title)
        box.setCustomSpacing(4, after: title)
        add(control)
        control.setAccessibilityTitleUIElement(title)
        title.setAccessibilityServesAsTitleForUIElements([control])
        return title
    }

    /// A full-width control (a field, popup or button).
    func add(_ control: NSView) {
        if let control = control as? NSControl { control.controlSize = .regular }
        box.addArrangedSubview(control)
        control.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    }

    /// An 11 pt wrapping caption, optionally describing `control` for VoiceOver.
    @discardableResult
    func addCaption(_ text: String, describing control: NSView? = nil) -> NSTextField {
        let caption = NSTextField(wrappingLabelWithString: text)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.preferredMaxLayoutWidth = contentWidth
        caption.isSelectable = false
        captions.append(caption)
        box.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        if let control { control.setAccessibilityHelp(text) }
        return caption
    }

    /// Extra space after the last row (between one row group and the next).
    func addGap(_ gap: CGFloat = 8) {
        if let last = box.arrangedSubviews.last { box.setCustomSpacing(gap, after: last) }
    }

    func apply(_ theme: ChiefTheme) {
        titleLabel.textColor = theme.textSecondary
        box.layer?.backgroundColor = theme.raisedFill.cgColor
        box.layer?.borderColor = theme.hairline.cgColor
        for label in labels { label.textColor = theme.textPrimary }
        for caption in captions { caption.textColor = theme.textSecondary }
    }
}
