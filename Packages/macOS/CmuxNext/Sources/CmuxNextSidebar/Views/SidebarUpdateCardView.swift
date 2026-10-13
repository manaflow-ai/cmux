import AppKit
import CmuxNextDesign
import QuartzCore

/// The staged update card above the sidebar footer (UPDATE-CARD, Arc-style
/// in cmux's colors): the theme's surface with a hairline border, "cmux
/// <version> is ready", up to three changelog lines, the Automatic Updates
/// checkbox, one full-width Restart to Update button (one click installs and
/// relaunches; disabled, Installing…, once taken) and a full-width quiet "See
/// all changes" under it (the What's New page; stacked, so neither label
/// truncates in a narrow sidebar, cx-7rone). Hovering the card or its button shows the
/// update's highlights popover (the React surface, cx-urd.61.2). Hidden without a
/// staged update.
final class SidebarUpdateCardView: NSView {
    var onInstall: (() -> Void)?
    var onAutomaticUpdates: ((Bool) -> Void)?
    /// "See all changes": the What's New page for the staged update.
    var onOpenChanges: (() -> Void)?
    private(set) var card: SidebarUpdateCard?
    private let titleLabel = NSTextField(labelWithString: "")
    /// The short version and build date.
    private let detailLabel = NSTextField(labelWithString: "")
    /// The first changelog lines, one label each.
    private var lineLabels: [NSTextField] = []
    /// "See all changes": the full list (cx-lntk, in the app since cx-7rone).
    let seeAllButton = SidebarUpdateButton()
    let checkbox = SidebarUpdateCheckbox()
    let button = SidebarUpdateButton()
    /// The staged update's highlights (the React ready surface; set by the sidebar).
    var highlights: (any SidebarSurfaceIsland)? {
        didSet {
            popover = nil
            oldValue?.view.removeFromSuperview()
            highlights?.onAction = { [weak self] in self?.hideNotes() }
            parkHighlights()
        }
    }

    /// Makes ``highlights`` once a card shows: each is a web page, and two
    /// per window built at launch with no update staged cost about 50 ms of
    /// main thread before the first frame.
    var surfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            highlights?.close()
            highlights = card == nil ? nil : surfaces?.island(.ready)
        }
    }

    /// The highlights page waits in the card's view tree, transparent,
    /// click-through and outside the card's bounds, so it loads and reports
    /// its height while the card shows; the popover takes it while open and
    /// gives it back when it closes.
    func parkHighlights() {
        guard let highlights, highlights.view.superview !== parking else { return }
        if parking.superview == nil { addSubview(parking, positioned: .below, relativeTo: nil) }
        parking.frame = NSRect(x: SidebarIslandParking.offscreenX, y: 0, width: Self.popoverWidth, height: max(1, highlights.contentHeight))
        highlights.view.removeFromSuperview()
        highlights.view.frame = parking.bounds
        highlights.view.autoresizingMask = [.width, .height]
        parking.addSubview(highlights.view)
    }
    var popover: NSPopover?
    /// The highlights page's place while the popover is closed.
    let parking = SidebarIslandParking()
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
        seeAllButton.isQuiet = true
        seeAllButton.onPress = { [weak self] in
            self?.hideNotes()
            self?.onOpenChanges?()
        }
        [titleLabel, detailLabel, checkbox, button, seeAllButton].forEach(addSubview)
        button.onPress = { [weak self] in self?.onInstall?() }
        checkbox.onToggle = { [weak self] on in self?.onAutomaticUpdates?(on) }
        setAccessibilityElement(false)
        isHidden = true
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `card`, or hides the view (and its popover) for nil. The
    /// highlights page is made when a card first shows, so it has loaded
    /// and measured before the first hover, and closed when the card goes.
    func configure(_ card: SidebarUpdateCard?) {
        guard card != self.card else { return }
        self.card = card
        isHidden = card == nil
        guard let card else {
            // The card went away: its page goes too (a web page per window
            // kept loaded with no staged update, cx-asynu).
            hideNotes()
            highlights?.close()
            highlights = nil
            return
        }
        if highlights == nil { highlights = surfaces?.island(.ready) }
        titleLabel.stringValue = card.title
        detailLabel.stringValue = card.detail ?? ""
        detailLabel.isHidden = card.detail == nil
        lineLabels.forEach { $0.removeFromSuperview() }
        lineLabels = card.lines.prefix(Self.maxLines).map { line in
            let label = NSTextField(labelWithString: "• " + line)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.themedToolTip = line
            addSubview(label)
            return label
        }
        seeAllButton.isHidden = card.seeAllTitle == nil
        seeAllButton.configure(title: card.seeAllTitle ?? "", enabled: true, help: nil)
        checkbox.configure(title: card.automaticUpdatesTitle, isOn: card.automaticUpdates)
        button.configure(title: card.buttonTitle, enabled: card.isEnabled,
                         help: [card.notes.headline, card.notes.keepsRunning].joined(separator: " "))
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space3 }
    private static var titleFont: NSFont { Typography.bodyEmphasized }

    /// Changelog lines the card shows (the popover's three highlights).
    static let maxLines = 3
    private static var captionHeight: CGFloat { ceil(Typography.caption.boundingRectForFont.height) }

    /// The card's height for `card`: padding, title, the detail and changelog
    /// lines when present, the checkbox row, the button, "See all changes"
    /// when present, padding.
    static func height(for card: SidebarUpdateCard) -> CGFloat {
        let title = ceil(titleFont.boundingRectForFont.height)
        let lines = CGFloat((card.detail == nil ? 0 : 1) + min(card.lines.count, maxLines))
        let seeAll = card.seeAllTitle == nil ? 0 : Metrics.space1 + SidebarUpdateButton.height
        return ceil(padding + title + (lines > 0 ? Metrics.space1 + lines * captionHeight : 0) + Metrics.space2
            + SidebarUpdateCheckbox.height + Metrics.space3 + SidebarUpdateButton.height + seeAll + padding)
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
        // Restart to Update and See all changes stack, each full width: side
        // by side both truncated below a 260 pt sidebar (nxdog93, cx-7rone).
        button.frame = NSRect(x: pad, y: checkbox.frame.maxY + Metrics.space3, width: width, height: SidebarUpdateButton.height)
        seeAllButton.frame = NSRect(x: pad, y: button.frame.maxY + Metrics.space1, width: width, height: SidebarUpdateButton.height)
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
