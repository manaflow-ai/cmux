import CoreGraphics

/// Width math for the leading glass workspace title menu.
///
/// The workspace title belongs beside the back button, not in the centered
/// principal slot. Reserve the trailing toolbar cluster and the leading back
/// control so the title truncates before it can underlap native toolbar items;
/// beyond those reserves the title may use all remaining bar width.
///
/// iOS overflows toolbar items into a trailing More menu whenever the bar's
/// contents do not fit, and below iOS 27 there is no public priority to keep
/// specific items in the bar. The title therefore must never claim space the
/// trailing items actually render with. Callers report the measured content
/// widths of the trailing toolbar items; the estimate constants only cover the
/// frames before the first measurement arrives.
struct MobileLeadingToolbarTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool
    /// Sum of the measured content widths of the structurally visible trailing
    /// toolbar items, 0 until the first layout pass reports them.
    let measuredTrailingItemsWidth: CGFloat
    /// How many of the structurally visible trailing items have reported a
    /// measurement. A structural item without one (it just appeared and its
    /// geometry callback has not fired yet) must still reserve fallback space,
    /// or the title claims the new item's room and bounces it into More.
    let measuredTrailingItemCount: Int
    /// How many trailing toolbar items are structurally visible right now;
    /// each carries its own glass capsule chrome around the measured content.
    let trailingItemCount: Int
    /// Rendered distance from the title content's leading edge to the
    /// leading-most trailing item content's leading edge, when every
    /// structural trailing item and the title label have reported geometry at
    /// the current pane width (LTR only). This is the system's realized
    /// layout, so a cap derived from it can only consume space that is
    /// actually empty on screen: unlike the estimate constants it can never
    /// over-commit the bar and bounce trailing items into the More menu.
    let measuredTitleToTrailingSpan: CGFloat?

    static let backButtonReserve: CGFloat = 44
    static let trailingReserveBase: CGFloat = 64
    static let chatToggleReserve: CGFloat = 60
    static let barMarginsAndSpacing: CGFloat = 84
    /// Horizontal glass-capsule chrome around one trailing item's content.
    static let trailingItemChrome: CGFloat = 24
    /// Safe content-width reserve for a structural item that has not reported
    /// geometry yet.
    static let unmeasuredTrailingItemReserve: CGFloat = 64
    static let unmeasuredFallback: CGFloat = 140
    static let floor: CGFloat = 96
    /// Subtracted from the measured span before the title may use it: the
    /// title pill's trailing glass chrome plus the trailing capsule's leading
    /// chrome (~13pt each) plus a minimum visual gap matching the
    /// back-to-title spacing (~13pt).
    static let spanGapReserve: CGFloat = 40

    init(
        contentWidth: CGFloat,
        hasBackButton: Bool,
        hasTrailingCluster: Bool,
        hasChatToggle: Bool,
        measuredTrailingItemsWidth: CGFloat = 0,
        measuredTrailingItemCount: Int = 0,
        trailingItemCount: Int = 0,
        measuredTitleToTrailingSpan: CGFloat? = nil
    ) {
        self.contentWidth = contentWidth
        self.hasBackButton = hasBackButton
        self.hasTrailingCluster = hasTrailingCluster
        self.hasChatToggle = hasChatToggle
        self.measuredTrailingItemsWidth = measuredTrailingItemsWidth
        self.measuredTrailingItemCount = measuredTrailingItemCount
        self.trailingItemCount = trailingItemCount
        self.measuredTitleToTrailingSpan = measuredTitleToTrailingSpan
    }

    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        // Realized-layout path: both edges of the gap were measured at this
        // width, so size the title from actual positions. The title's leading
        // edge and the trailing items' positions do not depend on the title's
        // width, so this does not feed back into itself.
        if let span = measuredTitleToTrailingSpan, span > 0 {
            return max(0, span - Self.spanGapReserve)
        }
        let leading = hasBackButton ? Self.backButtonReserve : 0
        return max(0, contentWidth - leading - trailingReserve - Self.barMarginsAndSpacing)
    }

    private var trailingReserve: CGFloat {
        if measuredTrailingItemCount > 0 {
            let unmeasured = CGFloat(max(trailingItemCount - measuredTrailingItemCount, 0))
            return measuredTrailingItemsWidth
                + CGFloat(max(trailingItemCount, 1)) * Self.trailingItemChrome
                + unmeasured * Self.unmeasuredTrailingItemReserve
        }
        guard hasTrailingCluster else { return 0 }
        return Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
    }
}
