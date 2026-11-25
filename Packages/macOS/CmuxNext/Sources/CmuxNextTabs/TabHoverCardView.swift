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
///
/// Leo 2026-11-07 ("is the length of it based off of anything? ... Or should we have it just be the
/// same size of the, like max width of a tab?"; "Does this need so many symbols?"): the card is as
/// wide as a tab at its widest, its leading edge on the tab's (`HoverCardPanel.rest`), and grows
/// only for a long path, to `maxWidth`. Only the title row has a glyph, the tab's own; the rows
/// under it are plain text on the title's leading edge.
final class TabHoverCardView: NSView {
    private static var padding: CGFloat { HoverCardStyle.shared.padding }
    static var thumbnailSize: CGSize {
        // 16:10, inside a card as wide as a full tab.
        let width = restWidth - 2 * padding
        return CGSize(width: width, height: (width * 10 / 16).rounded())
    }

    /// The card's width with no long path: a tab at its widest.
    static var restWidth: CGFloat { Metrics.tabMaxWidth }
    /// The widest a long path grows the card; past it the path truncates in its middle.
    static var maxWidth: CGFloat { (Metrics.tabMaxWidth * 1.5).rounded() }
    private static var iconSize: CGFloat { HoverCardRowView.iconSize }
    /// The card's width now: `restWidth`, or wider for the shown tab's path.
    private(set) var cardWidth: CGFloat = TabHoverCardView.restWidth
    private var widthConstraint: NSLayoutConstraint?
    private var rowsLeading: NSLayoutConstraint?

    let titleLabel = ChromeLabel(wrappingLabelWithString: "")
    /// The tab's own glyph (its favicon, symbol or agent mark), leading the title; the rows under it start on the title's text.
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

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = HoverCardStyle.shared.titleFont
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.restWidth - 2 * Self.padding
        kindIcon.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = HoverCardStyle.shared.rowGap
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
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            kindIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            kindIcon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -Self.iconSize / 3),
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
        let rowsTop = rows.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HoverCardStyle.shared.titleGap)
        let top = thumbnail.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: HoverCardStyle.shared.mediaGap)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        let trailing = titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p)
        let width = content.widthAnchor.constraint(equalToConstant: Self.restWidth)
        let rowsLeading = rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p)
        NSLayoutConstraint.activate([leading, rowsTop, top, height, trailing, width, rowsLeading])
        widthConstraint = width
        self.rowsLeading = rowsLeading
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
            setCardWidth(Self.restWidth)
            set(placeRow, HoverCardRowContent(text: lines.joined(separator: "\n"), lines: lines.count))
            for row in [statusRow, detailRow, memoryRow] { set(row, nil) }
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
        setCardWidth(Self.width(forPlace: lines.place, textLeading: textLeading))
        // Plain text under the title: the title's glyph is the card's one icon.
        set(placeRow, lines.place.map { HoverCardRowContent(text: $0) }, truncation: .byTruncatingMiddle)
        // The run state as a dot in its color, unless the title's indicator already shows it.
        let tone = TabHoverCardLines.tone(item)
        set(statusRow, lines.status.map {
            HoverCardRowContent(text: $0, accessory: activity.isHidden ? tone.map(HoverCardAccessory.dot) : nil)
        })
        set(detailRow, lines.detail.map { HoverCardRowContent(text: $0, ink: .tertiary) })
        set(memoryRow, lines.memory.map { HoverCardRowContent(text: $0, accessory: cpuBars()) })
    }

    /// The card's width for `place` (a folder and branch, a page's address): `restWidth`, or as
    /// wide as the path needs up to `maxWidth`.
    static func width(forPlace place: String?, textLeading: CGFloat) -> CGFloat {
        guard let place, !place.isEmpty else { return restWidth }
        let text = (place as NSString).size(withAttributes: [.font: HoverCardStyle.shared.secondaryFont]).width
        return min(max(restWidth, (textLeading + text + padding).rounded(.up)), maxWidth)
    }

    /// Where the title's text and the rows under it start: past the title's glyph when it has one.
    private var textLeading: CGFloat {
        switch item?.icon {
        case .none?, nil: Self.padding
        default: Self.padding + Self.iconSize + Metrics.space2
        }
    }

    private func setCardWidth(_ width: CGFloat) {
        cardWidth = width
        widthConstraint?.constant = width
        rowsLeading?.constant = textLeading
        thumbnailHeight?.constant = thumbnail.isHidden ? 0 : Self.thumbnailHeight(cardWidth: width)
        updateTitleWidth()
    }

    /// 16:10 across the card inside its padding.
    private static func thumbnailHeight(cardWidth: CGFloat) -> CGFloat {
        ((cardWidth - 2 * padding) * 10 / 16).rounded()
    }

    /// The memory row's bars: the tab's CPU over the last seconds, warm at a core, hot at two.
    private func cpuBars() -> HoverCardAccessory? {
        guard !cpuHistory.isEmpty else { return nil }
        let newest = cpuHistory.last ?? 0
        let tone: HoverCardTone = newest >= 2 ? .danger : newest >= 1 ? .attention : .secondary
        let peak = max(1, cpuHistory.max() ?? 0)
        return .bars(cpuHistory.map { $0 / peak }, tone: tone)
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
        titleLeading?.constant = Self.padding + (kindIcon.isHidden ? 0 : Self.iconSize + Metrics.space2)
        rowsLeading?.constant = titleLeading?.constant ?? Self.padding
        updateTitleWidth()
    }

    /// A row shows only with content; a stack row that hides gives up its line.
    private func set(_ row: HoverCardRowView, _ content: HoverCardRowContent?, truncation: NSLineBreakMode = .byTruncatingTail) {
        if let content, !content.text.isEmpty {
            let style = HoverCardStyle.shared
            let live = Typography.system(.monospacedDigit, size: style.secondaryFont.pointSize, weight: .regular)
            row.configure(content, image: nil, font: row === statusRow || row === memoryRow ? live : style.secondaryFont,
                          wrapWidth: cardWidth - (rowsLeading?.constant ?? Self.padding) - Self.padding, truncation: truncation)
            row.isHidden = false
        } else {
            row.isHidden = true
        }
        rowsTop?.constant = rows.arrangedSubviews.allSatisfy(\.isHidden) ? 0 : HoverCardStyle.shared.titleGap
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
        titleLabel.preferredMaxLayoutWidth = cardWidth - (titleLeading?.constant ?? Self.padding) - trailing
    }

    /// What the card's program status line reads ("" when hidden).
    var detailText: String { detailRow.isHidden ? "" : detailRow.textLabel.stringValue }

    var showsThumbnail: Bool { !thumbnail.isHidden }

    func setThumbnailVisible(_ visible: Bool) {
        thumbnail.isHidden = !visible
        thumbnailHeight?.constant = visible ? Self.thumbnailHeight(cardWidth: cardWidth) : 0
        thumbnailTop?.constant = visible ? HoverCardStyle.shared.mediaGap : 0
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
