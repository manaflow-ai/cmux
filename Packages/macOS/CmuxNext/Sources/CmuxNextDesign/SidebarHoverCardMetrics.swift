public import CoreGraphics

/// The workspace hover card's sizes at one sidebar density and text size (``SidebarRowTokens/hoverCard``), in
/// points. A pinned row and a list row open the same card, so it follows the rows it opens from (Lawrence
/// 2026-11-03: "make sure size of the pinned summary thing reflect size of ui compactness i chose").
public nonisolated struct SidebarHoverCardMetrics: Equatable, Sendable {
    /// Around the card's content.
    public var padding: CGFloat
    /// The card's one icon column: the kind icon, the status mark, each fact's and each tab's icon.
    public var iconSide: CGFloat
    /// The name and a tab's title.
    public var titleSize: CGFloat
    /// The summary, age, stats and a tab's detail line.
    public var captionSize: CGFloat
    /// The card's width before a long name wraps.
    public var width: CGFloat
    /// The widest the card grows to show a tab's whole detail line.
    public var maxWidth: CGFloat
    public var minWidth: CGFloat
    /// The full history layout's width.
    public var logWidth: CGFloat
    /// How much wider than the sidebar the card may be beside a narrow sidebar.
    public var sidebarReach: CGFloat
    /// How tall the history grows before it scrolls: the default card, and the full history.
    public var timelineMaxHeight: CGFloat
    public var logMaxHeight: CGFloat
    /// A tab row with its title alone, and with its detail line under the title.
    public var tabRowHeight: CGFloat
    public var tabRowHeightTwoLines: CGFloat
    /// The "Show details" row.
    public var disclosureHeight: CGFloat

    public init(padding: CGFloat, iconSide: CGFloat, titleSize: CGFloat, captionSize: CGFloat, width: CGFloat,
                maxWidth: CGFloat, minWidth: CGFloat, logWidth: CGFloat, sidebarReach: CGFloat,
                timelineMaxHeight: CGFloat, logMaxHeight: CGFloat, tabRowHeight: CGFloat,
                tabRowHeightTwoLines: CGFloat, disclosureHeight: CGFloat) {
        self.padding = padding
        self.iconSide = iconSide
        self.titleSize = titleSize
        self.captionSize = captionSize
        self.width = width
        self.maxWidth = maxWidth
        self.minWidth = minWidth
        self.logWidth = logWidth
        self.sidebarReach = sidebarReach
        self.timelineMaxHeight = timelineMaxHeight
        self.logMaxHeight = logMaxHeight
        self.tabRowHeight = tabRowHeight
        self.tabRowHeightTwoLines = tabRowHeightTwoLines
        self.disclosureHeight = disclosureHeight
    }

    /// The card's text column, in titles: 22 at a 12 pt title is the shipped 264 pt (280 pt with the padding).
    public static let textColumnInTitles: CGFloat = 22
    /// The widest card's text column, in titles: room for a tab's whole detail line.
    public static let maxTextColumnInTitles: CGFloat = 26
    public static let minTextColumnInTitles: CGFloat = 14
    /// The full history's text column, in titles: a prompt reads in longer lines.
    public static let logTextColumnInTitles: CGFloat = 27
    /// How far past a narrow sidebar the card may reach, in titles.
    public static let sidebarReachInTitles: CGFloat = 10
    /// How many rows of history show before it scrolls: the default card, and the full history.
    public static let timelineRows: CGFloat = 9
    public static let logRows: CGFloat = 15
}
