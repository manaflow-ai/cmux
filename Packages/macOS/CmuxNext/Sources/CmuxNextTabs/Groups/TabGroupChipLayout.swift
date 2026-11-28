public import CoreGraphics

/// Pure chip sizing. The chip view measures text; this turns the measured
/// widths into the pill and slot widths layout uses.
public struct TabGroupChipLayout {
    public init() {}
    /// What the chip shows.
    public struct Content: Equatable, Sendable {
        public var nameWidth: CGFloat
        /// Collapsed member count text width, or nil when expanded.
        public var countWidth: CGFloat?
        /// The group icon's side, or 0 without an icon.
        public var iconWidth: CGFloat

        public init(nameWidth: CGFloat, countWidth: CGFloat?, iconWidth: CGFloat = 0) {
            self.nameWidth = nameWidth
            self.countWidth = countWidth
            self.iconWidth = iconWidth
        }

        /// Whether the chip is the bare color dot: no name, count or icon.
        public var isDot: Bool { nameWidth == 0 && countWidth == nil && iconWidth == 0 }
    }

    /// The icon's width plus its gap to the name or count that follows; 0 without an icon.
    public static func iconAdvance(_ content: Content, metrics: TabStripMetrics) -> CGFloat {
        guard content.iconWidth > 0 else { return 0 }
        return content.iconWidth + (content.nameWidth > 0 || content.countWidth != nil ? metrics.groupChipIconSpacing : 0)
    }

    /// Width of the colored pill. An unnamed expanded group without an icon is a dot.
    public static func pillWidth(_ content: Content, metrics: TabStripMetrics) -> CGFloat {
        let name = min(content.nameWidth, metrics.groupChipMaxNameWidth)
        var inner: CGFloat = iconAdvance(content, metrics: metrics) + name
        if let count = content.countWidth {
            inner += (name > 0 ? metrics.groupChipCountSpacing : 0) + count
        }
        guard inner > 0 else { return metrics.groupChipDotSize }
        return (inner + 2 * metrics.groupChipPadding).rounded(.up)
    }

    /// Width of the chip's layout slot.
    public static func slotWidth(_ content: Content, metrics: TabStripMetrics) -> CGFloat {
        pillWidth(content, metrics: metrics) + 2 * metrics.groupChipOuterInset
    }
}
