import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// One tab in the workspace hover card's tab list, laid out by frame on the card's grid
/// (Lawrence msg 19245: "alignment here looks bad"): its icon on the card's icon column, its title and
/// detail line on the card's text column, its trailing text and status mark at the end. The row reaches
/// `fillOutset` past both edges of the list, so its hover fill has room around the icon while the icon
/// stays on the column.
@MainActor
final class WorkspaceTabHoverCardRow: NSView {
    /// How far the row (and its hover fill) reaches past the list's leading and trailing edges.
    static var fillOutset: CGFloat { Metrics.space2 }

    private let style: WorkspaceTabHoverCardStyle
    private let icon = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    /// The muted line: place, state and time (`WorkspaceTabHoverCardLine`).
    private let detail = ChromeLabel(labelWithString: "")
    private let trailingLabel = ChromeLabel(labelWithString: "")
    private let activity = StatusIndicatorView()
    /// The unread dot, on the status mark's place when the tab has no status of its own.
    private let unreadDot = NSView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { paint() } }
    var isKeyboardSelected = false { didSet { paint() } }
    var onRelease: (() -> Void)?
    private var pressed = false
    private var pressedTabID: TabID?
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
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        detail.font = Typography.caption
        // The line fits itself (`WorkspaceTabHoverCardLine.detail(fitting:font:)`): only the place shortens.
        detail.lineBreakMode = .byClipping
        trailingLabel.font = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        activity.tracksWindowOcclusion = true
        unreadDot.wantsLayer = true
        unreadDot.isHidden = true
        for view in [icon, title, detail, trailingLabel, activity, unreadDot] { addSubview(view) }
        addTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: SidebarTab, now: Date) {
        let sameTab = currentTabID == tab.id
        currentTabID = tab.id
        if !sameTab {
            pressed = false
            pressedTabID = nil
        }
        isHovered = false
        let side = WorkspaceHoverCardView.iconSize
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: side, height: side)) }
            ?? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
            ?? NSImage.icon(tab.kind.icon, size: side)
        let line = WorkspaceTabHoverCardLine(tab, style: style, now: now)
        self.line = line
        let shownTitle = WorkspaceTabHoverCardLine.title(tab)
        title.stringValue = shownTitle
        detail.stringValue = line.detail
        trailingLabel.stringValue = line.trailing ?? ""
        trailingLabel.isHidden = line.trailing == nil
        state = tab.state
        // The shared arc spinner for active work; a user's pulsing-dot preference must not turn this
        // status into a dot. Working-look preferences may restyle `.working` into a breathing dot, so
        // its progress shows as loading and this surface always shows an arc.
        activity.configure(tab.state.isWorking ? .busy(progress: tab.state.progress) : tab.state, style: .arc)
        unreadDot.isHidden = !tab.isUnread || tab.state.isVisible
        let words = [shownTitle, line.detail, line.trailing, tab.isUnread ? Strings.unreadDot : nil]
        setAccessibilityLabel(words.compactMap { $0 }.joined(separator: ", "))
        reportedLine = [shownTitle, line.detail, line.trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        applyColors()
        needsLayout = true
    }

    /// The width the row needs to show its title and its whole detail line, fill outsets included.
    var preferredWidth: CGFloat {
        let outset = Self.fillOutset
        let text = style.twoLines
            ? max(title.naturalSize.width, detailWidth(line?.detail ?? ""))
            : title.naturalSize.width + Metrics.space3 + detailWidth(line?.detail ?? "")
        let trailing = trailingLabel.isHidden ? 0 : trailingLabel.naturalSize.width + Metrics.space3
        return ceil(2 * outset + WorkspaceHoverCardView.textInset + text + trailing + Metrics.space2 + Metrics.smallIconSize)
    }

    private func detailWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: detail.font ?? Typography.caption]).width) + 2 * detail.alignmentRectInsets.left
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Frame-laid: a new width lays the texts out again (a first pass at a narrower width truncated them).
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let outset = Self.fillOutset
        let side = WorkspaceHoverCardView.iconSize
        let mark = Metrics.smallIconSize
        let textX = outset + WorkspaceHoverCardView.textInset
        // Frame sizes (`naturalSize`): a label's intrinsic size leaves out its 2 pt side padding.
        let titleSize = title.naturalSize
        let titlePad = title.alignmentRectInsets.left, detailPad = detail.alignmentRectInsets.left
        let titleTop = style.twoLines
            ? ((bounds.height - titleSize.height - detail.naturalSize.height) / 2).rounded()
            : ((bounds.height - titleSize.height) / 2).rounded()
        // The middle of the title's capitals: the icon, the status mark and the trailing text center on it.
        let capMiddle = titleTop + title.firstBaselineOffsetFromTop - (title.font?.capHeight ?? 0) / 2
        // The trailing column: the status mark at the end, its text left of it.
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
        activity.frame = CGRect(x: markX, y: (capMiddle - mark / 2).rounded(), width: mark, height: mark)
        let dot = Metrics.space3
        unreadDot.frame = CGRect(x: markX + (mark - dot) / 2, y: (capMiddle - dot / 2).rounded(), width: dot, height: dot)
        unreadDot.layer?.cornerRadius = dot / 2
        let textWidth = max(0, textEnd - textX)
        if let line, let font = detail.font {
            let room = style.twoLines ? textWidth : max(0, textWidth - min(titleSize.width, textWidth * 2 / 3) - Metrics.space3)
            detail.stringValue = line.detail(fitting: room, font: font)
        }
        let detailSize = detail.naturalSize
        if style.twoLines {
            title.frame = CGRect(x: textX - titlePad, y: titleTop, width: min(titleSize.width, textWidth + 2 * titlePad),
                                 height: titleSize.height)
            detail.frame = CGRect(x: textX - detailPad, y: titleTop + titleSize.height,
                                  width: min(detailSize.width, textWidth + 2 * detailPad), height: detailSize.height)
        } else {
            // One line: the title, then its detail on the title's baseline; the title keeps at least two
            // thirds of the line when both do not fit.
            let gap = Metrics.space3
            let wantedTitle = titleSize.width - 2 * titlePad, wantedDetail = detailSize.width - 2 * detailPad
            let titleWidth = max(0, min(wantedTitle, max(textWidth * 2 / 3, textWidth - wantedDetail - gap)))
            title.frame = CGRect(x: textX - titlePad, y: titleTop, width: titleWidth + 2 * titlePad, height: titleSize.height)
            let detailX = textX + titleWidth + gap
            let baseline = titleTop + title.firstBaselineOffsetFromTop
            detail.frame = CGRect(x: detailX - detailPad, y: (baseline - detail.firstBaselineOffsetFromTop).rounded(),
                                  width: max(0, min(detailSize.width, textEnd - detailX + 2 * detailPad)), height: detailSize.height)
        }
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            // Secondary, the token the card's facts use: tertiary washed the paths out on dark glass.
            detail.textColor = style.tintsState ? Self.stateTone(state) ?? Palette.textSecondary : Palette.textSecondary
            trailingLabel.textColor = Palette.textSecondary
            icon.contentTintColor = Palette.textSecondary
            unreadDot.layer?.backgroundColor = Palette.statusUnread.cgColor
        }
        paint()
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
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressedTabID = currentTabID
        paint()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onRelease?(); return onRelease != nil }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; paint() }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)), pressedTabID == currentTabID else { return }
        onRelease?()
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
