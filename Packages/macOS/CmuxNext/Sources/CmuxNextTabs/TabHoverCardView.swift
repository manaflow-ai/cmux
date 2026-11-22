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
    private let thumbnail = NSView()
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
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        thumbnail.layer?.actions = ["contents": Motion.crossfadeAction]

        for view in [titleLabel, subtitleLabel, resources, thumbnail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            resources.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Metrics.space1),
            resources.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            resources.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let top = thumbnail.topAnchor.constraint(equalTo: resources.bottomAnchor, constant: Metrics.space4)
        resourcesCollapsed = resources.heightAnchor.constraint(equalToConstant: 0)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        NSLayoutConstraint.activate([top, height])
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
            setResourcesVisible(true)
            setThumbnailVisible(true)
        case .group(let group, let titles):
            let shown = titles.prefix(Self.maxGroupLines)
            var lines = Array(shown)
            if titles.count > shown.count { lines.append(Strings.groupMore(titles.count - shown.count)) }
            configure(
                title: group.name.isEmpty ? Strings.groupTabCount(titles.count) : group.name,
                subtitle: lines.joined(separator: "\n"),
                lines: lines.count
            )
            setResourcesVisible(false)
            setThumbnailVisible(false)
        }
    }

    private func configure(title: String, subtitle: String?, lines: Int) {
        titleLabel.stringValue = title
        subtitleLabel.maximumNumberOfLines = lines
        subtitleLabel.lineBreakMode = lines > 1 ? .byTruncatingTail : .byTruncatingMiddle
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
    }

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

    func setThumbnailVisible(_ visible: Bool) {
        thumbnail.isHidden = !visible
        thumbnailHeight?.constant = visible ? Self.thumbnailSize.height : 0
        thumbnailTop?.constant = visible ? Metrics.space4 : 0
    }

    /// The thumbnail the card shows.
    private(set) var thumbnailImage: CGImage?

    func setThumbnail(_ image: CGImage?) {
        thumbnailImage = image
        guard let layer = thumbnail.layer else { return }
        performWithTheme {
            layer.backgroundColor = Palette.hoverFill.cgColor
        }
        Motion.transaction(.crossfade) { layer.contents = image }
    }
}
