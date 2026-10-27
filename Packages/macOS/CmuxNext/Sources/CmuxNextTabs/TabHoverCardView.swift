import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import QuartzCore

/// The tab and group chip card body. One instance per strip source is
/// reused for every card; the app's one `HoverCardPanel` hosts it.
///
/// A tab's card (`TabHoverCardLines`, Leo 2026-10-14; the Codex sidebar card, Leo 2026-10-19): the
/// tab's own glyph (a page's favicon) and title with the tab's status indicator, then one shared
/// row (`HoverCardRowView`) each for where it is, what it is doing (a colored dot when the title
/// shows no indicator), the program's own status words and its memory with the last seconds of
/// CPU as bars, then the thumbnail (Full previews). 13 pt rows on one leading edge.
final class TabHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space4 }
    static var thumbnailSize: CGSize {
        // 16:10, as wide as a full tab.
        CGSize(width: Metrics.tabMaxWidth, height: (Metrics.tabMaxWidth * 10 / 16).rounded())
    }

    static var cardWidth: CGFloat { thumbnailSize.width + 2 * padding }
    private static var iconSize: CGFloat { HoverCardRowView.iconSize }

    let titleLabel = ChromeLabel(wrappingLabelWithString: "")
    /// The tab's own glyph (its favicon, symbol or agent mark), leading the title on the rows' icon column.
    let kindIcon = NSImageView()
    /// Where the tab is (a page's host, a folder and branch), or a group's member titles.
    let placeRow = HoverCardRowView()
    /// What the tab does and for how long, and the agent's model.
    let statusRow = HoverCardRowView()
    /// The program's own words on its status (OSC 7501, cx-6so.36.9): one line, in a quieter
    /// color, so program text never reads as cmux's.
    let detailRow = HoverCardRowView()
    /// Memory (with CPU bars), or that the page hibernated.
    let memoryRow = HoverCardRowView()
    /// That the hidden tab uses high energy, with `discardButton` under it (`TabHoverCard+Energy.swift`).
    let energyRow = HoverCardRowView()
    let discardButton = ThemedBezelButton(frame: .zero)
    /// The tab's Discard: the controller's, for the tab the card shows.
    var onDiscard: (() -> Void)?
    /// The tab uses high energy (its source said so when the card was configured).
    var highEnergy = false
    /// The rows top to bottom; a hidden one gives up its line.
    private var rowViews: [HoverCardRowView] { [placeRow, statusRow, detailRow, memoryRow, energyRow] }
    private let thumbnail = NSView()
    /// The tab's status in the shared indicator, trailing the title's first line.
    /// Follows its panel's visibility node: the panel orders front after the card moves into it.
    private let activity = StatusIndicatorView()
    private static var indicatorSize: CGFloat { 13 }
    /// The frames of the content shown now; nil after a change until the next measure.
    private var measured: TabHoverCardLayout?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8
    /// The tab the card shows (nil for a group) and its latest sample.
    private var item: TabItem?
    private var report: ResourceReport?
    /// The tab's CPU of each sample since its card showed, newest last (the memory row's bars).
    private var cpuHistory: [Double] = []

    init() {
        super.init(frame: .zero)
        titleLabel.font = Typography.bodyEmphasized
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        kindIcon.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        for row in rowViews {
            row.isHidden = true
            // A row keeps its own constraints: it starts as wide as the card's rows, never at a zero
            // frame those constraints cannot meet.
            row.frame = CGRect(x: Self.padding, y: 0, width: Self.cardWidth - 2 * Self.padding, height: row.fittingSize.height)
            addSubview(row)
        }
        for view in [kindIcon, titleLabel, thumbnail, activity] {
            addSubview(view)
        }
        setUpDiscardButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Label colors in the card's theme scope (the strip's); the panel runs
    /// it on adopt and on every theme change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
            setKindIcon(tint: Palette.textSecondary)
        }
        for row in rowViews { row.applyColors() }
    }

    func configure(_ content: TabHoverCardContent) {
        switch content {
        case .tab(let item):
            if self.item?.id != item.id {
                report = nil
                cpuHistory.removeAll()
            }
            self.item = item
            setActivity(item.indicator, style: item.busyStyle)
            render()
            // The thumbnail frame is the controller's: it shows or hides once the tab's own is known.
        case .group(let group, let titles):
            item = nil
            report = nil
            cpuHistory.removeAll()
            let shown = titles.prefix(Self.maxGroupLines)
            var lines = Array(shown)
            if titles.count > shown.count { lines.append(Strings.groupMore(titles.count - shown.count)) }
            titleLabel.stringValue = group.name.isEmpty ? Strings.groupTabCount(titles.count) : group.name
            set(placeRow, HoverCardRowContent(text: lines.joined(separator: "\n"), lines: lines.count), icon: nil)
            setHighEnergy(false, discard: nil)
            for row in [statusRow, detailRow, memoryRow, energyRow] { set(row, nil, icon: nil) }
            setActivity(.idle, style: nil)
            setThumbnailVisible(false)
        }
        applyColors()
    }

    /// The tab's latest sample (or, for a hibernated page, its last one before); nil shows
    /// a dash until the first.
    func setResources(_ report: ResourceReport?) {
        // A redraw hands the same report again; only a new sample adds a bar.
        let fresh = report != nil && report != self.report
        self.report = report
        if fresh, let item, !item.isDormant, let row = report?.tabs.first(where: { $0.id == item.id.rawValue }),
           TabHoverCardLines.measured(row), let cpu = row.usage.cpu {
            cpuHistory.append(cpu)
            if cpuHistory.count > HoverCardAccessoryView.maxBars { cpuHistory.removeFirst(cpuHistory.count - HoverCardAccessoryView.maxBars) }
        }
        render()
    }

    /// The card hid: its next show starts with no bars, even for the same tab.
    func resetResourceHistory() {
        cpuHistory.removeAll()
        report = nil
    }

    private func render() {
        guard let item else { return }
        let lines = TabHoverCardLines.make(item, report: report, now: Date())
        titleLabel.stringValue = lines.title
        let facts = item.hover
        let placeIcon: NSImage? = switch facts.kind {
        case .browser: favicon(item) ?? NSImage.icon(.linkWeb, size: Self.iconSize)
        case .terminal, .agentChat: NSImage.icon(.folder, size: Self.iconSize)
        case .other: nil
        }
        set(placeRow, lines.place.map { HoverCardRowContent(text: $0) }, icon: placeIcon, truncation: .byTruncatingMiddle)
        // The run state as a dot in its color, unless the title's indicator already shows it.
        let tone = TabHoverCardLines.tone(item)
        set(statusRow, lines.status.map {
            HoverCardRowContent(text: $0, accessory: activity.isHidden ? tone.map(HoverCardAccessory.dot) : nil)
        }, icon: NSImage.icon(facts.kind == .terminal ? .terminal : .agentActivity, size: Self.iconSize))
        set(detailRow, lines.detail.map { HoverCardRowContent(text: $0, ink: .tertiary) },
            icon: NSImage.icon(.textDescription, size: Self.iconSize))
        set(memoryRow, lines.memory.map { HoverCardRowContent(text: $0, accessory: cpuBars()) },
            icon: NSImage.icon(.serverHealth, size: Self.iconSize))
        discardButton.isHidden = !highEnergy || item.isDormant
        set(energyRow, discardButton.isHidden ? nil : Self.energyContent, icon: NSImage.icon(.statusWarning, size: Self.iconSize))
    }

    /// The memory row's bars: the tab's CPU over the last seconds, warm at a core, hot at two.
    private func cpuBars() -> HoverCardAccessory? {
        guard !cpuHistory.isEmpty else { return nil }
        let newest = cpuHistory.last ?? 0
        let tone: HoverCardTone = newest >= 2 ? .danger : newest >= 1 ? .attention : .secondary
        let peak = max(1, cpuHistory.max() ?? 0)
        return .bars(cpuHistory.map { $0 / peak }, tone: tone)
    }

    /// A page's favicon, drawn as is.
    private func favicon(_ item: TabItem) -> NSImage? {
        guard case .image(let image) = item.icon else { return nil }
        return NSImage(cgImage: image.cgImage, size: NSSize(width: Self.iconSize, height: Self.iconSize))
    }

    /// The title's leading glyph: the tab's own icon, tinted like the strip draws it (a favicon as is).
    private func setKindIcon(tint: NSColor) {
        let scale = window?.backingScaleFactor ?? 2
        let size = Self.iconSize
        let cg: CGImage? = switch item?.icon {
        case .image(let image)?: image.cgImage
        case .agentMark(let brand)?:
            TabAgentMarkCache.shared.image(brand: brand, tint: tint, size: size, scale: scale)
        case .icon(let name)?:
            TabPackIconCache.shared.image(name: name, tint: tint, size: size, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: size, size: size, scale: scale)
        case .symbol(let name)?:
            TabSymbolCache.shared.image(named: name, tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale)
        case .none?, nil: nil
        }
        kindIcon.image = cg.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
        kindIcon.isHidden = kindIcon.image == nil
        updateTitleWidth()
    }

    /// A row shows only with content; a stack row that hides gives up its line.
    private func set(_ row: HoverCardRowView, _ content: HoverCardRowContent?, icon: NSImage?,
                     truncation: NSLineBreakMode = .byTruncatingTail) {
        if let content, !content.text.isEmpty {
            let live = Typography.system(.monospacedDigit, size: Typography.body.pointSize, weight: .regular)
            row.configure(content, image: icon, font: row === statusRow || row === memoryRow ? live : Typography.body,
                          wrapWidth: Self.cardWidth - 2 * Self.padding - Self.iconSize - Metrics.space2, truncation: truncation)
            row.isHidden = false
        } else {
            row.isHidden = true
        }
        invalidateCardLayout()
    }

    /// Shows the tab's state trailing the title, which gives up the indicator's width only while it draws.
    private func setActivity(_ state: StatusIndicatorState, style: StatusIndicatorStyle?) {
        activity.configure(state, style: style)
        updateTitleWidth()
    }

    /// The title wraps between its glyph and the indicator.
    private func updateTitleWidth() {
        titleLabel.preferredMaxLayoutWidth = TabHoverCardLayout.titleWidth(metrics: Self.layoutMetrics, showsKindIcon: !kindIcon.isHidden,
                                                                          showsActivity: !activity.isHidden)
        invalidateCardLayout()
    }

    // MARK: Frame layout

    /// The panel sizes and places its window from this (`HoverCardPanel.place`).
    override var intrinsicContentSize: NSSize { cardLayout.size }

    override var fittingSize: NSSize { cardLayout.size }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) re-frames the content
    }

    /// The content at the top of the card: a morph that lays the panel out larger keeps it there.
    override func layout() {
        super.layout()
        let layout = cardLayout
        let lift = bounds.height - layout.size.height
        // Alignment rects, as the constraints placed them: a label's frame keeps its 2 pt text padding outside.
        func place(_ view: NSView, _ frame: CGRect) { view.setAlignmentFrame(frame.offsetBy(dx: 0, dy: lift)) }
        place(titleLabel, layout.title)
        place(kindIcon, layout.kindIcon)
        place(activity, layout.activity)
        place(thumbnail, layout.thumbnail)
        for (row, frame) in zip(rowViews.filter { !$0.isHidden }, layout.rows) { place(row, frame) }
        // Discard takes the last row frame, under the energy row (`cardLayout`).
        if !discardButton.isHidden, let frame = layout.rows.last { place(discardButton, discardFrame(in: frame)) }
    }

    /// What the card's program status line reads ("" when hidden).
    var detailText: String { detailRow.isHidden ? "" : detailRow.textLabel.stringValue }

    var showsThumbnail: Bool { !thumbnail.isHidden }

    func setThumbnailVisible(_ visible: Bool) {
        guard thumbnail.isHidden == visible else { return }
        thumbnail.isHidden = !visible
        invalidateCardLayout()
    }

    /// The thumbnail the card shows.
    private(set) var thumbnailImage: CGImage?

    /// Only a thumbnail landing in an empty frame fades in; one tab's image
    /// replacing another's swaps at once (two tabs never blend).
    func setThumbnail(_ image: CGImage?) {
        let landing = thumbnailImage == nil && image != nil
        thumbnailImage = image
        guard let layer = thumbnail.layer else { return }
        performWithTheme {
            layer.backgroundColor = Palette.hoverFill.cgColor
        }
        layer.actions = landing ? ["contents": Motion.crossfadeAction] : nil
        Motion.hoverCards.transaction(landing ? .crossfade : nil) { layer.contents = image }
    }
}

extension TabHoverCardView {
    static var layoutMetrics: TabHoverCardLayout.Metrics {
        TabHoverCardLayout.Metrics(cardWidth: cardWidth, padding: padding, iconSize: iconSize, indicatorSize: indicatorSize,
                                   gap: Metrics.space2, thumbnailGap: Metrics.space4)
    }

    /// The card's frames for what it shows now: measured once per change, applied by `layout()`.
    var cardLayout: TabHoverCardLayout {
        if let measured { return measured }
        let content = TabHoverCardLayout.Content(
            showsKindIcon: !kindIcon.isHidden, showsActivity: !activity.isHidden,
            titleHeight: titleLabel.intrinsicContentSize.height, titleBaseline: titleLabel.firstBaselineOffsetFromTop,
            rowHeights: rowViews.filter { !$0.isHidden }.map { $0.fittingSize.height } + (discardButton.isHidden ? [] : [discardButton.fittingSize.height]),
            thumbnailHeight: thumbnail.isHidden ? nil : Self.thumbnailSize.height)
        let layout = TabHoverCardLayout(content: content, metrics: Self.layoutMetrics,
                                        rightToLeft: userInterfaceLayoutDirection == .rightToLeft)
        measured = layout
        return layout
    }

    /// The content changed: measure again on the next read, and lay out again.
    private func invalidateCardLayout() {
        measured = nil
        invalidateIntrinsicContentSize()
        needsLayout = true // invalidate: callers change the card's content (title, rows, glyph, indicator, thumbnail)
    }
}

extension TabHoverCardView: HoverCardTextReporting {
    /// The card's shown lines, top to bottom (`debug.hover_cards`, tests).
    var reportedLines: [String] {
        [titleLabel.stringValue] + rowViews.compactMap { row in
            guard !row.isHidden, !row.shownText.isEmpty else { return nil }
            return row.shownText
        } + (discardButton.isHidden ? [] : [discardButton.title])
    }
}
