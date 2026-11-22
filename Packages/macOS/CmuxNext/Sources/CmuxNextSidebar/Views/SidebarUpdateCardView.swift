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
        [titleLabel, checkbox, button].forEach(addSubview)
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

    /// The card's height: padding, title, checkbox, button, padding.
    static var height: CGFloat {
        let title = ceil(titleFont.boundingRectForFont.height)
        return ceil(padding + title + Metrics.space2 + SidebarUpdateCheckbox.height + Metrics.space3
            + SidebarUpdateButton.height + padding)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding
        layer?.cornerRadius = Metrics.space3
        titleLabel.font = Self.titleFont
        let width = max(0, b.width - 2 * pad)
        let th = ceil(Self.titleFont.boundingRectForFont.height)
        titleLabel.frame = NSRect(x: pad, y: pad, width: width, height: th)
        checkbox.frame = NSRect(x: pad, y: titleLabel.frame.maxY + Metrics.space2, width: width, height: SidebarUpdateCheckbox.height)
        button.frame = NSRect(x: pad, y: checkbox.frame.maxY + Metrics.space3, width: width, height: SidebarUpdateButton.height)
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            titleLabel.textColor = Palette.textPrimary
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
