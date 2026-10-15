import AppKit
import CmuxNextDesign
import CmuxNextResources
import QuartzCore

/// The tab and group chip card body. One instance per strip source is
/// reused for every card; the app's one `HoverCardPanel` hosts it.
///
/// A tab's card (`TabHoverCardLines`, Leo 2026-10-14): the title with the tab's
/// status indicator, then one caption row each for where it is, what it is doing,
/// the program's own status words and its memory, then the thumbnail (Full previews).
final class TabHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space5 }
    static var thumbnailSize: CGSize {
        // 16:10, as wide as a full tab.
        CGSize(width: Metrics.tabMaxWidth, height: (Metrics.tabMaxWidth * 10 / 16).rounded())
    }

    static var cardWidth: CGFloat { thumbnailSize.width + 2 * padding }

    let titleLabel = NSTextField(wrappingLabelWithString: "")
    /// Where the tab is (a page's host, a folder and branch), or a group's member titles.
    let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    /// What the tab does and for how long, and the agent's model.
    let statusLabel = TabHoverCardView.caption()
    /// The program's own words on its status (OSC 7501, cx-6so.36.9): one line, in a quieter
    /// color, so program text never reads as cmux's.
    let detailLabel = TabHoverCardView.caption()
    /// Memory, or that the page hibernated.
    let memoryLabel = TabHoverCardView.caption()
    private let rows = NSStackView()
    private let thumbnail = NSView()
    /// The tab's status in the shared indicator, trailing the title's first line.
    /// Follows its panel's occlusion: the panel orders front after the card moves into it.
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private var titleTrailing: NSLayoutConstraint?
    private var rowsTop: NSLayoutConstraint?
    private static var indicatorSize: CGFloat { 13 }
    private var thumbnailHeight: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8
    /// The tab the card shows (nil for a group) and its latest sample.
    private var item: TabItem?
    private var report: ResourceReport?

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = Typography.bodyEmphasized
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        subtitleLabel.font = Typography.caption
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        // Status and memory tick while the card shows: digits of one width keep them still.
        let live = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        statusLabel.font = live
        memoryLabel.font = live
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Metrics.space1
        for row in [subtitleLabel, statusLabel, detailLabel, memoryLabel] {
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        for view in [titleLabel, rows, thumbnail, activity] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            rows.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -Self.indicatorSize / 3),
            activity.widthAnchor.constraint(equalToConstant: Self.indicatorSize),
            activity.heightAnchor.constraint(equalToConstant: Self.indicatorSize),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let rowsTop = rows.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space1)
        let top = thumbnail.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: Metrics.space4)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        let trailing = titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p)
        NSLayoutConstraint.activate([rowsTop, top, height, trailing])
        self.rowsTop = rowsTop
        titleTrailing = trailing
        thumbnailTop = top
        thumbnailHeight = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func caption() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = Typography.caption
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Label colors in the card's theme scope (the strip's); the panel runs
    /// it on adopt and on every theme change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            subtitleLabel.textColor = Palette.textSecondary
            statusLabel.textColor = Palette.textSecondary
            memoryLabel.textColor = Palette.textSecondary
            detailLabel.textColor = Palette.textTertiary
            thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
        }
    }

    func configure(_ content: TabHoverCardContent) {
        switch content {
        case .tab(let item):
            if self.item?.id != item.id { report = nil }
            self.item = item
            subtitleLabel.maximumNumberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            setActivity(item.indicator, style: item.busyStyle)
            render()
            // The thumbnail frame is the controller's: it shows or hides once the tab's own is known.
        case .group(let group, let titles):
            item = nil
            report = nil
            let shown = titles.prefix(Self.maxGroupLines)
            var lines = Array(shown)
            if titles.count > shown.count { lines.append(Strings.groupMore(titles.count - shown.count)) }
            titleLabel.stringValue = group.name.isEmpty ? Strings.groupTabCount(titles.count) : group.name
            subtitleLabel.maximumNumberOfLines = lines.count
            subtitleLabel.lineBreakMode = .byTruncatingTail
            set(subtitleLabel, lines.joined(separator: "\n"))
            for label in [statusLabel, detailLabel, memoryLabel] { set(label, nil) }
            setActivity(.idle, style: nil)
            setThumbnailVisible(false)
        }
    }

    /// The tab's latest sample (or, for a hibernated page, its last one before); nil shows
    /// a dash until the first.
    func setResources(_ report: ResourceReport?) {
        self.report = report
        render()
    }

    private func render() {
        guard let item else { return }
        let lines = TabHoverCardLines.make(item, report: report, now: Date())
        titleLabel.stringValue = lines.title
        set(subtitleLabel, lines.place)
        set(statusLabel, lines.status)
        set(detailLabel, lines.detail)
        set(memoryLabel, lines.memory)
    }

    /// A row shows only with text; a stack row that hides gives up its line.
    private func set(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = (text ?? "").isEmpty
        rowsTop?.constant = rows.arrangedSubviews.allSatisfy(\.isHidden) ? 0 : Metrics.space1
    }

    /// Shows the tab's state trailing the title, which gives up the indicator's width only while it draws.
    private func setActivity(_ state: StatusIndicatorState, style: StatusIndicatorStyle?) {
        activity.configure(state, style: style)
        let inset = Self.padding + (activity.isHidden ? 0 : Self.indicatorSize + Metrics.space2)
        titleTrailing?.constant = -inset
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - Self.padding - inset
    }

    /// What the card's program status line reads ("" when hidden).
    var detailText: String { detailLabel.isHidden ? "" : detailLabel.stringValue }

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
        Motion.transaction(landing ? .crossfade : nil) { layer.contents = image }
    }
}

extension TabHoverCardView: HoverCardTextReporting {
    /// The card's shown lines, top to bottom (`debug.hover_cards`, tests).
    var reportedLines: [String] {
        [titleLabel.stringValue] + rows.arrangedSubviews.compactMap { view in
            guard !view.isHidden, let field = view as? NSTextField, !field.stringValue.isEmpty else { return nil }
            return field.stringValue
        }
    }
}
