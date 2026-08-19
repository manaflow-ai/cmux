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
    /// Sum of the measured content widths of every visible trailing toolbar
    /// item, 0 until the first layout pass reports them.
    let measuredTrailingItemsWidth: CGFloat
    /// How many trailing toolbar items are visible; each carries its own glass
    /// capsule chrome around the measured content.
    let trailingItemCount: Int

    static let backButtonReserve: CGFloat = 44
    static let trailingReserveBase: CGFloat = 64
    static let chatToggleReserve: CGFloat = 60
    static let barMarginsAndSpacing: CGFloat = 84
    /// Horizontal glass-capsule chrome around one trailing item's content.
    static let trailingItemChrome: CGFloat = 24
    static let unmeasuredFallback: CGFloat = 140
    static let floor: CGFloat = 96

    init(
        contentWidth: CGFloat,
        hasBackButton: Bool,
        hasTrailingCluster: Bool,
        hasChatToggle: Bool,
        measuredTrailingItemsWidth: CGFloat = 0,
        trailingItemCount: Int = 0
    ) {
        self.contentWidth = contentWidth
        self.hasBackButton = hasBackButton
        self.hasTrailingCluster = hasTrailingCluster
        self.hasChatToggle = hasChatToggle
        self.measuredTrailingItemsWidth = measuredTrailingItemsWidth
        self.trailingItemCount = trailingItemCount
    }

    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = hasBackButton ? Self.backButtonReserve : 0
        return max(0, contentWidth - leading - trailingReserve - Self.barMarginsAndSpacing)
    }

    private var trailingReserve: CGFloat {
        if measuredTrailingItemsWidth > 0 {
            return measuredTrailingItemsWidth
                + CGFloat(max(trailingItemCount, 1)) * Self.trailingItemChrome
        }
        guard hasTrailingCluster else { return 0 }
        return Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
    }
}
