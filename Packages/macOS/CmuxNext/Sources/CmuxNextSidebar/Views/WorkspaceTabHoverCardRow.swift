import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// One tab in the workspace hover card's tab list, laid out by frame on the card's grid
/// (Lawrence msg 19245: "alignment here looks bad"): its icon on the card's icon column, its title and
/// detail line on the card's text column, its status mark right after the title on the title's line, its
/// trailing text at the end, and on hover a ✕ there that closes the tab (Leo 2026-11-02: "YOU SHOULD BE ABLE
/// TO CLOSE THESE TABS FROM THE HOVER PREVIEW" / "PLUS THE PLACEMENT LOOKS LIKE SHIT"). The row reaches
/// `fillOutset` past both edges of the list, so its hover fill has room around the icon while the icon
/// stays on the column.
@MainActor
final class WorkspaceTabHoverCardRow: NSView {
    /// How far the row (and its hover fill) reaches past the list's leading and trailing edges.
    static var fillOutset: CGFloat { Metrics.space2 }

    private let style: WorkspaceTabHoverCardStyle
    private let icon = NSImageView()
    /// The tab's favicon as the sidebar's favicon style draws it (the one favicon path, `SidebarFaviconRenditions`).
    private let faviconRenditions = SidebarFaviconRenditions()
    /// The favicon shown, drawn again when the theme or the favicon style changes.
    private var favicon: SidebarFavicon?
    private let title = ChromeLabel(labelWithString: "")
    /// The muted line: place, state and time (`WorkspaceTabHoverCardLine`).
    private let detail = ChromeLabel(labelWithString: "")
    private let trailingLabel = ChromeLabel(labelWithString: "")
    private let activity = StatusIndicatorView()
    /// The unread dot, on the status mark's place when the tab has no status of its own.
    private let unreadDot = NSView()
    /// Closes the tab; shown while the row is hovered, on the trailing slot.
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: Strings.hoverCardCloseTab)
    private var tracking: NSTrackingArea?
    /// Set by the pointer (and by the gallery, to show the ✕).
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            paint()
            updateCloseButton()
        }
    }
    var isKeyboardSelected = false { didSet { paint() } }
    /// Focuses this row's tab: run on the press (u2819), as a pane tab and a sidebar row do, and by VoiceOver's press.
    var onActivate: (() -> Void)?
    /// The ✕ was pressed: close this row's tab (the card stays open).
    var onClose: (() -> Void)? { didSet { updateCloseButton() } }
    private var pressed = false
    private(set) var reportedLine = ""
    private var currentTabID: TabID?
    private var state: StatusIndicatorState = .idle
    /// The shown tab's line; the detail label shows it fitted to the row (`layout`).
    private var line: WorkspaceTabHoverCardLine?

    override var isFlipped: Bool { true }

    init(style: WorkspaceTabHoverCardStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SidebarDensityTokens.rowCornerRadius
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        // The line fits itself (`WorkspaceTabHoverCardLine.detail(fitting:font:)`): the place shortens first, and
        // a line still too long ends in an ellipsis, never cut off at the card's edge.
        detail.lineBreakMode = .byTruncatingTail
        activity.tracksWindowOcclusion = true
        unreadDot.wantsLayer = true
        unreadDot.isHidden = true
        closeButton.showsLabelToolTip = false
        // The card's panel never becomes key: the first click on the ✕ must close, as the row's own click selects.
        closeButton.takesFirstClick = true
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        for view in [icon, title, detail, trailingLabel, activity, unreadDot, closeButton] { addSubview(view) }
        addTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: SidebarTab, now: Date, machine: SidebarMachine? = nil) {
        let sameTab = currentTabID == tab.id
        currentTabID = tab.id
        // The same tab configured again (the card shown again for its workspace) keeps its hover state, so
        // nothing on the row redraws.
        if !sameTab {
            pressed = false
            isHovered = false
        }
        // The card's text at the sidebar's density and text size, taken again on every configure (the rows are reused).
        let card = WorkspaceHoverCardView.tokens
        title.font = Typography.system(.default, size: card.titleSize, weight: .regular)
        detail.font = Typography.system(.default, size: card.captionSize, weight: .regular)
        trailingLabel.font = Typography.system(.monospacedDigit, size: card.captionSize, weight: .regular)
        let side = WorkspaceHoverCardView.iconSize
        favicon = tab.favicon
        icon.image = tab.favicon.map(faviconImage)
            // A site with no favicon (yet): the workspace rows' placeholder globe (`WorkspaceIcon.pagePlaceholder`).
            ?? (tab.host != nil ? NSImage.icon(symbol: WorkspaceIcon.pagePlaceholderSymbol, size: side) : nil)
            ?? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
            ?? NSImage.icon(tab.kind.icon, size: side)
        let line = WorkspaceTabHoverCardLine(tab, style: style, now: now, machine: machine)
        self.line = line
        let shownTitle = WorkspaceTabHoverCardLine.title(tab)
        title.stringValue = shownTitle
        detail.stringValue = line.detail
        // A tab with no fact worth a line shows its title alone, centered (no "Tab" under "New Tab").
        detail.isHidden = line.detail.isEmpty
        trailingLabel.stringValue = line.trailing ?? ""
        trailingLabel.isHidden = line.trailing == nil
        state = tab.state
        // The shared arc spinner for active work; a user's pulsing-dot preference must not turn this
        // status into a dot. Working-look preferences may restyle `.working` into a breathing dot, so
        // its progress shows as loading and this surface always shows an arc.
        activity.configure(tab.state.isWorking ? .busy(progress: tab.state.progress) : tab.state, style: .arc)
        unreadDot.isHidden = !tab.isUnread || tab.state.isVisible
        let words = [shownTitle, line.detail.isEmpty ? nil : line.detail, line.trailing, tab.isUnread ? Strings.unreadDot : nil]
        setAccessibilityLabel(words.compactMap { $0 }.joined(separator: ", "))
        reportedLine = [shownTitle, line.detail, line.trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        applyColors()
        needsLayout = true
    }

    /// The row shows a detail line under (or after) its title; a two-line row without one is one row tall.
    var hasDetail: Bool { !detail.isHidden }

    /// The title's font and the icon's frame, as drawn (tests).
    var titleFont: NSFont? { title.font }
    var iconFrame: CGRect { icon.frame }

    /// The width the row needs to show its title and its whole detail line, fill outsets included.
    var preferredWidth: CGFloat {
        let outset = Self.fillOutset
        let text = title.naturalSize.width + Metrics.space3 + detailWidth(line?.detail ?? "")
        let trailing = trailingLabel.isHidden ? 0 : trailingLabel.naturalSize.width + Metrics.space3
        // The status mark after the title, and the trailing slot the ✕ (or the unread dot) takes.
        let mark = activity.showsGlyph ? Metrics.space2 + Metrics.smallIconSize : 0
        let titleLine = title.naturalSize.width + mark
        let lines = style.twoLines ? max(titleLine, detailWidth(line?.detail ?? "")) : text + mark
        return ceil(2 * outset + WorkspaceHoverCardView.textInset + lines + trailing + Metrics.space2 + Metrics.smallIconSize)
    }

    private func detailWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: detail.font ?? Typography.system(.default, size: WorkspaceHoverCardView.tokens.captionSize, weight: .regular)]).width) + 2 * detail.alignmentRectInsets.left
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Frame-laid: a new width lays the texts out again (a first pass at a narrower width truncated them).
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        // The sidebar workspace row's corners (Lawrence 2026-11-09: "roundness needs to match roundness of the
        // workspace row itself"), read here so a density change follows.
        layer?.cornerRadius = SidebarDensityTokens.rowCornerRadius
        let outset = Self.fillOutset
        let side = WorkspaceHoverCardView.iconSize
        let mark = Metrics.smallIconSize
        let textX = outset + WorkspaceHoverCardView.textInset
        // Frame sizes (`naturalSize`): a label's intrinsic size leaves out its 2 pt side padding.
        let titleSize = title.naturalSize
        let titlePad = title.alignmentRectInsets.left, detailPad = detail.alignmentRectInsets.left
        let titleTop = style.twoLines && !detail.isHidden
            ? ((bounds.height - titleSize.height - detail.naturalSize.height) / 2).rounded()
            : ((bounds.height - titleSize.height) / 2).rounded()
        // The middle of the title's capitals: the icon, the status mark and the trailing text center on it.
        let capMiddle = titleTop + title.firstBaselineOffsetFromTop - (title.font?.capHeight ?? 0) / 2
        // The trailing slot at the end (the unread dot, or the ✕ on hover), its text left of it.
        let markX = bounds.width - outset - mark
        var textEnd = markX - Metrics.space2
        if !trailingLabel.isHidden {
            let size = trailingLabel.naturalSize
            let pad = trailingLabel.alignmentRectInsets.left
            let x = textEnd - size.width + pad
            let top = (capMiddle - trailingLabel.firstBaselineOffsetFromTop + (trailingLabel.font?.capHeight ?? 0) / 2).rounded()
            trailingLabel.frame = CGRect(x: x, y: top, width: size.width, height: size.height)
            textEnd = x + pad - Metrics.space3
        }
        icon.frame = CGRect(x: outset, y: (capMiddle - side / 2).rounded(), width: side, height: side)
        closeButton.frame = CGRect(x: markX, y: (capMiddle - mark / 2).rounded(), width: mark, height: mark)
        let dot = Metrics.space3
        unreadDot.frame = CGRect(x: markX + (mark - dot) / 2, y: (capMiddle - dot / 2).rounded(), width: dot, height: dot)
        unreadDot.layer?.cornerRadius = dot / 2
        let textWidth = max(0, textEnd - textX)
        // The status mark sits right after the title, centred on its capitals; the title gives it room.
        let showsMark = activity.showsGlyph
        let markRoom = showsMark ? Metrics.space2 + mark : 0
        if let line, let font = detail.font {
            let room = style.twoLines ? textWidth : max(0, textWidth - min(titleSize.width, textWidth * 2 / 3) - Metrics.space3)
            detail.stringValue = line.detail(fitting: room, font: font)
        }
        let detailSize = detail.naturalSize
        if style.twoLines {
            title.frame = CGRect(x: textX - titlePad, y: titleTop, width: min(titleSize.width, max(0, textWidth - markRoom) + 2 * titlePad),
                                 height: titleSize.height)
            detail.frame = CGRect(x: textX - detailPad, y: titleTop + titleSize.height,
                                  width: min(detailSize.width, textWidth + 2 * detailPad), height: detailSize.height)
        } else {
            // One line: the title, then its detail on the title's baseline; the title keeps at least two
            // thirds of the line when both do not fit.
            let gap = Metrics.space3
            let wantedTitle = titleSize.width - 2 * titlePad, wantedDetail = detailSize.width - 2 * detailPad
            let titleWidth = max(0, min(wantedTitle, max(textWidth * 2 / 3, textWidth - wantedDetail - gap) - markRoom))
            title.frame = CGRect(x: textX - titlePad, y: titleTop, width: titleWidth + 2 * titlePad, height: titleSize.height)
            let detailX = textX + titleWidth + markRoom + gap
            let baseline = titleTop + title.firstBaselineOffsetFromTop
            detail.frame = CGRect(x: detailX - detailPad, y: (baseline - detail.firstBaselineOffsetFromTop).rounded(),
                                  width: max(0, min(detailSize.width, textEnd - detailX + 2 * detailPad)), height: detailSize.height)
        }
        activity.frame = CGRect(x: title.frame.maxX - titlePad + Metrics.space2, y: (capMiddle - mark / 2).rounded(), width: mark, height: mark)
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            // Secondary, the token the card's facts use: tertiary washed the paths out on dark glass.
            detail.textColor = style.tintsState ? Self.stateTone(state) ?? Palette.textSecondary : Palette.textSecondary
            trailingLabel.textColor = Palette.textSecondary
            // A low-contrast mono favicon draws in the card's label colour (Lawrence msg 19869); a glyph in the secondary ink.
            if let favicon { icon.image = faviconImage(favicon) }
            icon.contentTintColor = favicon == nil ? Palette.textSecondary : Palette.textPrimary
            unreadDot.layer?.backgroundColor = Palette.statusUnread.cgColor
        }
        paint()
    }

    /// `favicon` as the sidebar's favicon style draws it on the card (its glass over the window background), in this
    /// row's theme. Its bitmap is made once per image and style and kept.
    private func faviconImage(_ favicon: SidebarFavicon) -> NSImage {
        faviconRenditions.onStyleChange = { [weak self] in self?.applyColors() }
        return performWithTheme {
            faviconRenditions.drawing(favicon, side: WorkspaceHoverCardView.iconSize, scale: window?.backingScaleFactor ?? 2,
                                      ground: SidebarFaviconRenditions.groundLuminance(Palette.windowBackground)).image
        }
    }

    /// A needs-you or failed tab's status color (the sidebar's status colors); nil otherwise.
    private static func stateTone(_ state: StatusIndicatorState) -> NSColor? {
        switch state {
        case .waiting: Palette.statusAttention
        case .error: Palette.statusError
        default: nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    /// The ✕ shows on the hovered row in the trailing slot, over the unread dot.
    private func updateCloseButton() {
        closeButton.isHidden = !isHovered || onClose == nil
        unreadDot.alphaValue = closeButton.isHidden ? 1 : 0
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// The press focuses the tab at once (Lawrence u2819: "why is mouse-down tab focus unimplemented?");
    /// the pressed fill stays until the release, which acts on nothing.
    override func mouseDown(with event: NSEvent) {
        pressed = true
        paint()
        onActivate?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The ✕ takes its own click; anywhere else the row is one button.
        return hit === closeButton || hit.isDescendant(of: closeButton) ? hit : self
    }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return onActivate != nil }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        paint()
    }

    private func addTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func paint() {
        performWithTheme {
            let fill = pressed || isKeyboardSelected ? Palette.pressedFill : (isHovered ? Palette.hoverFill : .clear)
            if let layer { ChromeHover.paint(layer, fill, animated: false) }
        }
    }
}
