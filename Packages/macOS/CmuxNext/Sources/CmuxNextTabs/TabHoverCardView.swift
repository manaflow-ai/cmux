import AppKit
import CmuxNextDesign
import CmuxNextResources
import QuartzCore

/// The tab and group chip card body. One instance per strip source is
/// reused for every card; the app's one `HoverCardPanel` hosts it.
final class TabHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space5 }
    static var thumbnailSize: CGSize {
        // 16:10, as wide as a full tab.
        CGSize(width: Metrics.tabMaxWidth, height: (Metrics.tabMaxWidth * 10 / 16).rounded())
    }

    static var cardWidth: CGFloat { thumbnailSize.width + 2 * padding }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var subtitleTop: NSLayoutConstraint?
    private var subtitleCollapsed: NSLayoutConstraint?
    /// The program's own words on its status (OSC 7501, cx-6so.36.9): one line, apart from the
    /// card's own facts above it and in a quieter color, so program text never reads as cmux's.
    private let detailLabel = NSTextField(labelWithString: "")
    private var detailTop: NSLayoutConstraint?
    private var detailCollapsed: NSLayoutConstraint?
    private let thumbnail = NSView()
    /// The tab's status in the shared indicator, trailing the title's first line.
    /// Follows its panel's occlusion: the panel orders front after the card moves into it.
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private var titleTrailing: NSLayoutConstraint?
    private static var indicatorSize: CGFloat { 13 }
    /// CPU and memory of the hovered tab (tab cards only).
    let resources = ResourceSummaryView()
    private var resourcesCollapsed: NSLayoutConstraint?
    private var thumbnailHeight: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8

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
        detailLabel.font = Typography.caption
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill

        for view in [titleLabel, subtitleLabel, detailLabel, resources, thumbnail, activity] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            activity.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -Self.indicatorSize / 3),
            activity.widthAnchor.constraint(equalToConstant: Self.indicatorSize),
            activity.heightAnchor.constraint(equalToConstant: Self.indicatorSize),
            resources.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: Metrics.space1),
            resources.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            resources.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let top = thumbnail.topAnchor.constraint(equalTo: resources.bottomAnchor, constant: Metrics.space4)
        resourcesCollapsed = resources.heightAnchor.constraint(equalToConstant: 0)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        let detail = detailLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor)
        let subtitle = subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space1)
        let trailing = titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p)
        NSLayoutConstraint.activate([top, height, detail, subtitle, trailing])
        titleTrailing = trailing
        subtitleTop = subtitle
        // A hidden label keeps its line in Auto Layout; an empty subtitle gives it up.
        subtitleCollapsed = subtitleLabel.heightAnchor.constraint(equalToConstant: 0)
        detailTop = detail
        detailCollapsed = detailLabel.heightAnchor.constraint(equalToConstant: 0)
        setDetail(nil)
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
            subtitleLabel.textColor = Palette.textSecondary
            detailLabel.textColor = Palette.textTertiary
            thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
        }
    }

    func configure(_ content: TabHoverCardContent) {
        switch content {
        case .tab(let item):
            let profile = item.profileBadge.map { Strings.browserProfile($0.name) }
            let subtitle = [profile, item.machineBadgeHelp, item.themeBadge.map { Strings.axTheme($0.name) }, item.subtitle]
                .compactMap(\.self).joined(separator: " · ")
            configure(title: item.title.isEmpty ? Strings.untitled : item.title, subtitle: subtitle.isEmpty ? nil : subtitle, lines: 1)
            setDetail(item.statusDetail)
            setActivity(item.indicator, style: item.busyStyle)
            // The thumbnail frame is the controller's: it shows or hides once the tab's own is known.
            setResourcesVisible(true)
        case .group(let group, let titles):
            let shown = titles.prefix(Self.maxGroupLines)
            var lines = Array(shown)
            if titles.count > shown.count { lines.append(Strings.groupMore(titles.count - shown.count)) }
            configure(
                title: group.name.isEmpty ? Strings.groupTabCount(titles.count) : group.name,
                subtitle: lines.joined(separator: "\n"),
                lines: lines.count
            )
            setDetail(nil)
            setActivity(.idle, style: nil)
            setResourcesVisible(false)
            setThumbnailVisible(false)
        }
    }

    /// Shows the tab's state trailing the title, which gives up the indicator's width only while it draws.
    private func setActivity(_ state: StatusIndicatorState, style: StatusIndicatorStyle?) {
        activity.configure(state, style: style)
        let inset = Self.padding + (activity.isHidden ? 0 : Self.indicatorSize + Metrics.space2)
        titleTrailing?.constant = -inset
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - Self.padding - inset
    }

    private func configure(title: String, subtitle: String?, lines: Int) {
        titleLabel.stringValue = title
        subtitleLabel.maximumNumberOfLines = lines
        subtitleLabel.lineBreakMode = lines > 1 ? .byTruncatingTail : .byTruncatingMiddle
        subtitleLabel.stringValue = subtitle ?? ""
        let shown = !(subtitle ?? "").isEmpty
        subtitleLabel.isHidden = !shown
        subtitleCollapsed?.isActive = !shown
        subtitleTop?.constant = shown ? Metrics.space1 : 0
    }

    /// The card's program status line; nil or empty collapses it.
    private func setDetail(_ text: String?) {
        let shown = !(text ?? "").isEmpty
        detailLabel.stringValue = text ?? ""
        detailLabel.isHidden = !shown
        detailCollapsed?.isActive = !shown
        detailTop?.constant = shown ? Metrics.space1 : 0
    }

    /// What the card's program status line reads ("" when hidden).
    var detailText: String { detailLabel.isHidden ? "" : detailLabel.stringValue }

    private func setResourcesVisible(_ visible: Bool) {
        resources.isHidden = !visible
        resourcesCollapsed?.isActive = !visible
        if !visible { resources.show(nil) }
    }

    /// Shows the latest sample; nil shows the placeholder line. A tab with
    /// no numbers to report (an agent chat, the New Tab page) shows none.
    func setResources(_ report: ResourceReport?) {
        let unavailable = report?.tabs.first.map { !$0.available } ?? false
        setResourcesVisible(!unavailable)
        if !unavailable { resources.show(report) }
    }

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
