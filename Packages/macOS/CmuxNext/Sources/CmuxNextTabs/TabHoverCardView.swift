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
    private let rows = NSStackView()
    private let thumbnail = NSView()
    /// The tab's status in the shared indicator, trailing the title's first line.
    /// Follows its panel's occlusion: the panel orders front after the card moves into it.
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private var titleTrailing: NSLayoutConstraint?
    private var titleLeading: NSLayoutConstraint?
    private var rowsTop: NSLayoutConstraint?
    private static var indicatorSize: CGFloat { 13 }
    private var thumbnailHeight: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8
    /// The tab the card shows (nil for a group) and its latest sample.
    private var item: TabItem?
    private var report: ResourceReport?
    /// The tab's CPU of each sample since its card showed, newest last (the memory row's bars).
    private var cpuHistory: [Double] = []
    /// The owner's icon images (``TabIconCaches``), which the title's glyph draws from.
    private let iconCaches: TabIconCaches

    init(iconCaches: TabIconCaches) {
        self.iconCaches = iconCaches
        super.init(frame: .zero)
        let content = self
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
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Metrics.space2
        for row in [placeRow, statusRow, detailRow, memoryRow] {
            row.isHidden = true
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        for view in [kindIcon, titleLabel, rows, thumbnail, activity] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            kindIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            kindIcon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -Self.iconSize / 3),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -Self.indicatorSize / 3),
            activity.widthAnchor.constraint(equalToConstant: Self.indicatorSize),
            activity.heightAnchor.constraint(equalToConstant: Self.indicatorSize),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let leading = titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p)
        let rowsTop = rows.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space2)
        let top = thumbnail.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: Metrics.space4)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        let trailing = titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p)
        NSLayoutConstraint.activate([leading, rowsTop, top, height, trailing])
        titleLeading = leading
        self.rowsTop = rowsTop
        titleTrailing = trailing
        thumbnailTop = top
        thumbnailHeight = height
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
        for row in [placeRow, statusRow, detailRow, memoryRow] { row.applyColors() }
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
            for row in [statusRow, detailRow, memoryRow] { set(row, nil, icon: nil) }
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
            iconCaches.agentMarks.image(brand: brand, tint: tint, size: size, scale: scale)
        case .icon(let name)?:
            iconCaches.packIcons.image(name: name, tint: tint, size: size, scale: scale)
                ?? iconCaches.symbols.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                            tint: tint, pointSize: size, size: size, scale: scale)
        case .symbol(let name)?:
            iconCaches.symbols.image(named: name, tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale)
        case .none?, nil: nil
        }
        kindIcon.image = cg.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
        kindIcon.isHidden = kindIcon.image == nil
        titleLeading?.constant = Self.padding + (kindIcon.isHidden ? 0 : Self.iconSize + Metrics.space2)
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
        rowsTop?.constant = rows.arrangedSubviews.allSatisfy(\.isHidden) ? 0 : Metrics.space2
    }

    /// Shows the tab's state trailing the title, which gives up the indicator's width only while it draws.
    private func setActivity(_ state: StatusIndicatorState, style: StatusIndicatorStyle?) {
        activity.configure(state, style: style)
        let inset = Self.padding + (activity.isHidden ? 0 : Self.indicatorSize + Metrics.space2)
        titleTrailing?.constant = -inset
        updateTitleWidth()
    }

    /// The title wraps between its glyph and the indicator.
    private func updateTitleWidth() {
        let trailing = Self.padding + (activity.isHidden ? 0 : Self.indicatorSize + Metrics.space2)
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - (titleLeading?.constant ?? Self.padding) - trailing
    }

    /// What the card's program status line reads ("" when hidden).
    var detailText: String { detailRow.isHidden ? "" : detailRow.textLabel.stringValue }

    var showsThumbnail: Bool { !thumbnail.isHidden }

    func setThumbnailVisible(_ visible: Bool) {
        thumbnail.isHidden = !visible
        thumbnailHeight?.constant = visible ? Self.thumbnailSize.height : 0
        thumbnailTop?.constant = visible ? Metrics.space4 : 0
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

extension TabHoverCardView: HoverCardTextReporting {
    /// The card's shown lines, top to bottom (`debug.hover_cards`, tests).
    var reportedLines: [String] {
        [titleLabel.stringValue] + rows.arrangedSubviews.compactMap { view in
            guard !view.isHidden, let row = view as? HoverCardRowView, !row.shownText.isEmpty else { return nil }
            return row.shownText
        }
    }
}
