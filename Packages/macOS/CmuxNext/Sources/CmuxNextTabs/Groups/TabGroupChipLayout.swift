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

        public init(nameWidth: CGFloat, countWidth: CGFloat?) {
            self.nameWidth = nameWidth
            self.countWidth = countWidth
        }
    }

    /// Width of the colored pill. An unnamed expanded group is a dot.
    public static func pillWidth(_ content: Content, metrics: TabStripMetrics) -> CGFloat {
        let name = min(content.nameWidth, metrics.groupChipMaxNameWidth)
        var inner: CGFloat = name
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
