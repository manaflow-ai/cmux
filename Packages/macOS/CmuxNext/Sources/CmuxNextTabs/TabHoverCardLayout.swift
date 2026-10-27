import CoreGraphics

/// The frames of a tab's hover card (``TabHoverCardView``): the title between the tab's glyph and
/// its status indicator, the shown rows under it on the card's leading edge, then the thumbnail.
/// A pure function of the card's metrics and its content's measured sizes, so the card lays out in
/// `layout()` without a constraint solve and reports its size to the panel that hosts it, as a
/// Chromium view does (`views::View::CalculatePreferredSize` and `Layout()`, ui/views/view.cc; the
/// tab hover card is chrome/browser/ui/views/tabs/tab_hover_card_bubble_view.cc).
///
/// Frames are in the card's unflipped coordinates (y up), for a card of `size`.
nonisolated struct TabHoverCardLayout: Equatable, Sendable {
    nonisolated struct Metrics: Equatable, Sendable {
        var cardWidth: CGFloat
        var padding: CGFloat
        var iconSize: CGFloat
        var indicatorSize: CGFloat
        /// Between the glyph or indicator and the title, between the title and the rows, between rows.
        var gap: CGFloat
        /// Between the rows and the thumbnail.
        var thumbnailGap: CGFloat
    }

    /// What the card shows, measured.
    nonisolated struct Content: Equatable, Sendable {
        var showsKindIcon: Bool
        var showsActivity: Bool
        /// The title's height at ``TabHoverCardLayout/titleWidth(metrics:showsKindIcon:showsActivity:)``.
        var titleHeight: CGFloat
        /// The title's first baseline, from its top.
        var titleBaseline: CGFloat
        /// The shown rows' heights, top to bottom.
        var rowHeights: [CGFloat]
        /// The thumbnail's height; nil while it is hidden.
        var thumbnailHeight: CGFloat?
    }

    var size: CGSize
    var title: CGRect
    var kindIcon: CGRect
    var activity: CGRect
    var rows: [CGRect]
    var thumbnail: CGRect

    /// The title's width: the card less its padding, less the glyph and the indicator while they show.
    static func titleWidth(metrics m: Metrics, showsKindIcon: Bool, showsActivity: Bool) -> CGFloat {
        m.cardWidth - leadingInset(m, showsKindIcon) - trailingInset(m, showsActivity)
    }

    init(content c: Content, metrics m: Metrics, rightToLeft: Bool = false) {
        let p = m.padding
        let inner = m.cardWidth - 2 * p
        // Top-down first (distances from the card's top), turned to y up at the end.
        let leading = Self.leadingInset(m, c.showsKindIcon)
        let titleWidth = Self.titleWidth(metrics: m, showsKindIcon: c.showsKindIcon, showsActivity: c.showsActivity)
        let title = CGRect(x: leading, y: p, width: titleWidth, height: c.titleHeight)
        // The glyph and the indicator center a third of their height above the title's first baseline.
        let baseline = p + c.titleBaseline
        let icon = CGRect(x: p, y: baseline - m.iconSize / 3 - m.iconSize / 2, width: m.iconSize, height: m.iconSize)
        let activity = CGRect(x: m.cardWidth - p - m.indicatorSize, y: baseline - m.indicatorSize / 3 - m.indicatorSize / 2,
                              width: m.indicatorSize, height: m.indicatorSize)
        var y = title.maxY + (c.rowHeights.isEmpty ? 0 : m.gap)
        var rows: [CGRect] = []
        for (index, height) in c.rowHeights.enumerated() {
            if index > 0 { y += m.gap }
            rows.append(CGRect(x: p, y: y, width: inner, height: height))
            y += height
        }
        if c.thumbnailHeight != nil { y += m.thumbnailGap }
        let thumbnail = CGRect(x: p, y: y, width: inner, height: c.thumbnailHeight ?? 0)
        let height = (thumbnail.maxY + p).rounded(.up)
        size = CGSize(width: m.cardWidth, height: height)
        func placed(_ rect: CGRect) -> CGRect {
            let x = rightToLeft ? m.cardWidth - rect.maxX : rect.minX
            return CGRect(x: x, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        self.title = placed(title)
        kindIcon = placed(icon)
        self.activity = placed(activity)
        self.rows = rows.map(placed)
        self.thumbnail = placed(thumbnail)
    }

    private static func leadingInset(_ m: Metrics, _ showsKindIcon: Bool) -> CGFloat {
        m.padding + (showsKindIcon ? m.iconSize + m.gap : 0)
    }

    private static func trailingInset(_ m: Metrics, _ showsActivity: Bool) -> CGFloat {
        m.padding + (showsActivity ? m.indicatorSize + m.gap : 0)
    }
}
