import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// One tab in the workspace hover card's tab list (u9696): its icon (a page's favicon, the agent's
/// mark, else its kind), its title, and under it the detail line (the program's status words, the
/// folder, the page's host, the agent); on the trailing edge the tab bar's status mark, a page's
/// sound or sleep, and the unread dot. Frame layout, no constraints inside: the card lays out up
/// to ``WorkspaceHoverCardView/visibleTabLimit`` of these per hover, reused card to card.
final class WorkspaceHoverCardTabRowView: NSView {
    static var iconSize: CGFloat { 13 }
    private static var markSize: CGFloat { 11 }

    private let icon = DecorativeImageView()
    let titleLabel = ChromeLabel(labelWithString: "")
    let detailLabel = ChromeLabel(labelWithString: "")
    private let indicator: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private let mark = DecorativeImageView()
    private let unreadDot = UnreadBadgeView()
    /// The tab this row shows; a click selects it.
    private(set) var tabID: TabID?
    /// Its width pinned to the list's while it is arranged (`WorkspaceHoverCardTabsView`).
    var widthPin: NSLayoutConstraint?
    private var hasDetail = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = Typography.caption
        detailLabel.lineBreakMode = .byTruncatingMiddle
        mark.isHidden = true
        unreadDot.isHidden = true
        [icon, titleLabel, detailLabel, indicator, mark, unreadDot].forEach(addSubview)
        setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The row as one line (tests, `debug.hover_cards`): the title, the detail, the status word.
    var shownText: String {
        [titleLabel.stringValue, hasDetail ? detailLabel.stringValue : nil, Strings.activity(indicator.state)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func configure(_ tab: SidebarTab) {
        tabID = tab.id
        titleLabel.stringValue = tab.title
        hasDetail = !(tab.detail ?? "").isEmpty
        detailLabel.stringValue = tab.detail ?? ""
        detailLabel.isHidden = !hasDetail
        icon.image = Self.icon(tab)
        indicator.configure(tab.state)
        indicator.isHidden = tab.state == .idle
        let symbol: String? = tab.flags.contains(.playing) ? "speaker.wave.2.fill"
            : tab.flags.contains(.muted) ? "speaker.slash.fill"
            : tab.flags.contains(.hibernated) ? "moon.zzz" : nil
        mark.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        mark.isHidden = mark.image == nil
        unreadDot.configure(tab.isUnread ? .dot : .none)
        unreadDot.isHidden = !tab.isUnread
        let flags = [tab.flags.contains(.playing) ? Strings.tabPlaying : nil, tab.flags.contains(.muted) ? Strings.tabMuted : nil,
                     tab.flags.contains(.hibernated) ? Strings.tabHibernated : nil, tab.isUnread ? Strings.unreadDot : nil]
        setAccessibilityLabel(([shownText] + flags.compactMap { $0 }).joined(separator: ", "))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// A page's favicon, the agent's mark, else the kind's icon.
    private static func icon(_ tab: SidebarTab) -> NSImage? {
        let side = iconSize
        if let favicon = tab.favicon { return NSImage(cgImage: favicon.image, size: NSSize(width: side, height: side)) }
        if let brand = tab.brand, let image = AgentBrandCatalog.templateImage(brand: brand, size: side) { return image }
        return NSImage.icon(tab.kind.icon, size: side)
    }

    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
            icon.contentTintColor = Palette.textSecondary
            mark.contentTintColor = Palette.textSecondary
        }
    }

    /// The trailing marks' width: the status mark, the page mark and the unread dot that show.
    private var trailingWidth: CGFloat {
        var width: CGFloat = 0
        if !indicator.isHidden { width += Self.iconSize + Metrics.space2 }
        if !mark.isHidden { width += Self.markSize + Metrics.space2 }
        if !unreadDot.isHidden { width += SidebarStyle.dotSize + Metrics.space2 }
        return width
    }

    override var intrinsicContentSize: NSSize {
        let text = max(titleLabel.intrinsicContentSize.width, hasDetail ? detailLabel.intrinsicContentSize.width : 0)
        let height = titleLabel.intrinsicContentSize.height + (hasDetail ? detailLabel.intrinsicContentSize.height : 0)
        return NSSize(width: Self.iconSize + Metrics.space2 + text + trailingWidth, height: height)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let titleSize = titleLabel.intrinsicContentSize
        icon.frame = NSRect(x: 0, y: (titleSize.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
        var trailing = b.width
        if !unreadDot.isHidden {
            let side = SidebarStyle.dotSize
            unreadDot.frame = NSRect(x: trailing - side, y: (titleSize.height - side) / 2, width: side, height: side)
            trailing = unreadDot.frame.minX - Metrics.space2
        }
        if !mark.isHidden {
            mark.frame = NSRect(x: trailing - Self.markSize, y: (titleSize.height - Self.markSize) / 2, width: Self.markSize, height: Self.markSize)
            trailing = mark.frame.minX - Metrics.space2
        }
        if !indicator.isHidden {
            indicator.frame = NSRect(x: trailing - Self.iconSize, y: (titleSize.height - Self.iconSize) / 2,
                                     width: Self.iconSize, height: Self.iconSize)
            trailing = indicator.frame.minX - Metrics.space2
        }
        let textX = Self.iconSize + Metrics.space2
        titleLabel.frame = NSRect(x: textX, y: 0, width: max(0, trailing - textX), height: titleSize.height)
        if hasDetail {
            detailLabel.frame = NSRect(x: textX, y: titleSize.height, width: max(0, b.width - textX),
                                       height: detailLabel.intrinsicContentSize.height)
        }
    }
}
