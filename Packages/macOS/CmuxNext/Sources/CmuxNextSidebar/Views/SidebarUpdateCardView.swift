import AppKit
import CmuxNextDesign
import QuartzCore

/// The staged update card above the sidebar footer (UPDATE-CARD, Arc-style
/// in cmux's colors): the theme's surface with a hairline border, "cmux
/// <version> is ready", the Automatic Updates checkbox and one full-width
/// Restart to Update button (one click installs and relaunches; disabled,
/// Installing…, once taken). Hovering the card or its button shows the
/// release notes popover (``SidebarUpdateNotesView``). Hidden without a
/// staged update.
final class SidebarUpdateCardView: NSView {
    var onInstall: (() -> Void)?
    var onAutomaticUpdates: ((Bool) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    private(set) var card: SidebarUpdateCard?
    private let titleLabel = NSTextField(labelWithString: "")
    /// The short version and build date.
    private let detailLabel = NSTextField(labelWithString: "")
    /// The first changelog lines, one label each.
    private var lineLabels: [NSTextField] = []
    /// "Release Notes": the full list (cx-lntk).
    let releaseNotesButton = SidebarUpdateButton()
    let checkbox = SidebarUpdateCheckbox()
    let button = SidebarUpdateButton()
    let notesView = SidebarUpdateNotesView()
    var popover: NSPopover?
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    private(set) var isHovered = false
    private var pointerHover: PointerHover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        releaseNotesButton.isQuiet = true
        releaseNotesButton.onPress = { [weak self] in
            guard let url = self?.card?.releaseNotesURL else { return }
            self?.hideNotes()
            self?.onOpenLink?(url)
        }
        [titleLabel, detailLabel, checkbox, releaseNotesButton, button].forEach(addSubview)
        button.onPress = { [weak self] in self?.onInstall?() }
        checkbox.onToggle = { [weak self] on in self?.onAutomaticUpdates?(on) }
        notesView.onOpenLink = { [weak self] url in
            self?.hideNotes()
            self?.onOpenLink?(url)
        }
        notesView.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
        setAccessibilityElement(false)
        isHidden = true
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `card`, or hides the view (and its popover) for nil.
    func configure(_ card: SidebarUpdateCard?) {
        guard card != self.card else { return }
        self.card = card
        isHidden = card == nil
        guard let card else {
            hideNotes()
            return
        }
        titleLabel.stringValue = card.title
        detailLabel.stringValue = card.detail ?? ""
        detailLabel.isHidden = card.detail == nil
        lineLabels.forEach { $0.removeFromSuperview() }
        lineLabels = card.lines.prefix(Self.maxLines).map { line in
            let label = NSTextField(labelWithString: "• " + line)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.toolTip = line
            addSubview(label)
            return label
        }
        releaseNotesButton.isHidden = card.releaseNotesTitle == nil || card.releaseNotesURL == nil
        releaseNotesButton.configure(title: card.releaseNotesTitle ?? "", enabled: true, help: card.releaseNotesURL?.absoluteString)
        checkbox.configure(title: card.automaticUpdatesTitle, isOn: card.automaticUpdates)
        button.configure(title: card.buttonTitle, enabled: card.isEnabled,
                         help: [card.notes.headline, card.notes.keepsRunning].joined(separator: " "))
        notesView.configure(card.notes)
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space3 }
    private static var titleFont: NSFont { Typography.bodyEmphasized }

    /// Changelog lines the card shows.
    static let maxLines = 4
    private static var captionHeight: CGFloat { ceil(Typography.caption.boundingRectForFont.height) }

    /// The card's height for `card`: padding, title, the detail and changelog
    /// lines when present, the checkbox row, the button, padding.
    static func height(for card: SidebarUpdateCard) -> CGFloat {
        let title = ceil(titleFont.boundingRectForFont.height)
        let lines = CGFloat((card.detail == nil ? 0 : 1) + min(card.lines.count, maxLines))
        return ceil(padding + title + (lines > 0 ? Metrics.space1 + lines * captionHeight : 0) + Metrics.space2
            + SidebarUpdateCheckbox.height + Metrics.space3 + SidebarUpdateButton.height + padding)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding
        layer?.cornerRadius = Metrics.space3
        titleLabel.font = Self.titleFont
        let width = max(0, b.width - 2 * pad)
        let th = ceil(Self.titleFont.boundingRectForFont.height)
        titleLabel.frame = NSRect(x: pad, y: pad, width: width, height: th)
        var y = titleLabel.frame.maxY
        let caption = Self.captionHeight
        if !detailLabel.isHidden || !lineLabels.isEmpty { y += Metrics.space1 }
        if !detailLabel.isHidden {
            detailLabel.font = Typography.caption
            detailLabel.frame = NSRect(x: pad, y: y, width: width, height: caption)
            y += caption
        }
        for label in lineLabels {
            label.font = Typography.caption
            label.frame = NSRect(x: pad, y: y, width: width, height: caption)
            y += caption
        }
        checkbox.frame = NSRect(x: pad, y: y + Metrics.space2, width: width, height: SidebarUpdateCheckbox.height)
        // Release Notes sits beside Restart to Update at its natural width;
        // beside the checkbox both labels truncated in a 260 pt sidebar.
        let notesWidth = releaseNotesButton.isHidden ? 0
            : min(width / 2, ceil((releaseNotesButton.title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
                + 2 * Metrics.space3)
        let buttonY = checkbox.frame.maxY + Metrics.space3, gap: CGFloat = notesWidth > 0 ? Metrics.space2 : 0
        button.frame = NSRect(x: pad, y: buttonY, width: max(0, width - notesWidth - gap), height: SidebarUpdateButton.height)
        releaseNotesButton.frame = NSRect(x: button.frame.maxX + gap, y: buttonY, width: notesWidth, height: SidebarUpdateButton.height)
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
            for label in lineLabels { label.textColor = Palette.textSecondary }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        notesView.applyColors()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideNotes() }
    }

    // MARK: Hover

    /// The pointer came onto the card: the notes show. It left (or the card
    /// moved or hid under it): the popover stays while the pointer went into
    /// it (to click a link), else it closes.
    private func setHovered(_ hovering: Bool) {
        isHovered = hovering
        if hovering { return showNotes() }
        guard !pointerIsOverNotes() else { return }
        hideNotes()
    }

    override func viewDidHide() {
        super.viewDidHide()
        pointerHover?.refresh()
    }
}
