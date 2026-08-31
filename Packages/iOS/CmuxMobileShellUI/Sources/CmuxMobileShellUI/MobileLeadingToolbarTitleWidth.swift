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
/// frames before the first measurement arrives. As a backstop, callers also
/// report when a trailing item's content left the bar (the system folded it
/// into More); that ratchets `collapseRecoveryReserve` on for the rest of the
/// view's lifetime so a collapse can never persist.
struct MobileLeadingToolbarTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
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
    /// True once a trailing item's content left the bar while structurally
    /// present (the system collapsed it into the More menu): the reserves
    /// undershot this device's real chrome, so give the space back.
    let hadTrailingCollapse: Bool

    static let backButtonReserve: CGFloat = 44
    static let trailingReserveBase: CGFloat = 64
    /// Dogfood on a 402pt iPhone 17 measured ~22pt of dead gap between the
    /// title pill and the trailing capsule under the original 84pt margin +
    /// 24pt/item chrome reserves. Only part of that slack is returned to the
    /// title (4pt here, 4pt per item below): larger-chrome devices proved
    /// able to eat the full amount (a 30pt trim collapsed the trailing items
    /// into More on an iPhone 17 Pro Max), and `collapseRecoveryReserve`
    /// backstops the remainder.
    static let barMarginsAndSpacing: CGFloat = 80
    /// Horizontal glass-capsule chrome around one trailing item's content.
    static let trailingItemChrome: CGFloat = 20
    /// Safe content-width reserve for a structural item that has not reported
    /// geometry yet.
    static let unmeasuredTrailingItemReserve: CGFloat = 64
    /// Added once a collapse was observed: more than the 12pt trimmed from
    /// the estimate reserves, so the recovered layout is strictly roomier
    /// than the original constants and the bar un-collapses.
    static let collapseRecoveryReserve: CGFloat = 28
    static let unmeasuredFallback: CGFloat = 140
    static let floor: CGFloat = 96

    init(
        contentWidth: CGFloat,
        hasBackButton: Bool,
        hasTrailingCluster: Bool,
        measuredTrailingItemsWidth: CGFloat = 0,
        measuredTrailingItemCount: Int = 0,
        trailingItemCount: Int = 0,
        hadTrailingCollapse: Bool = false
    ) {
        self.contentWidth = contentWidth
        self.hasBackButton = hasBackButton
        self.hasTrailingCluster = hasTrailingCluster
        self.measuredTrailingItemsWidth = measuredTrailingItemsWidth
        self.measuredTrailingItemCount = measuredTrailingItemCount
        self.trailingItemCount = trailingItemCount
        self.hadTrailingCollapse = hadTrailingCollapse
    }

    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = hasBackButton ? Self.backButtonReserve : 0
        let recovery = hadTrailingCollapse ? Self.collapseRecoveryReserve : 0
        return max(0, contentWidth - leading - trailingReserve - Self.barMarginsAndSpacing - recovery)
    }

    private var trailingReserve: CGFloat {
        if measuredTrailingItemCount > 0 {
            let unmeasured = CGFloat(max(trailingItemCount - measuredTrailingItemCount, 0))
            return measuredTrailingItemsWidth
                + CGFloat(max(trailingItemCount, 1)) * Self.trailingItemChrome
                + unmeasured * Self.unmeasuredTrailingItemReserve
        }
        guard hasTrailingCluster else { return 0 }
        // Nothing measured yet: the first layout pass after a (re)mount. The
        // structural item count is already known, so reserve fallback space
        // for every item beyond the cluster (the Changes chip on a connected
        // workspace), or the title over-claims on that first pass and the
        // system folds trailing items, sometimes the title itself, into the
        // More menu. A collapse born on the first pass never produces the
        // attach-then-detach signature the recovery ratchet watches for, so
        // it would stick until the next full remount.
        let extraStructuralItems = CGFloat(max(trailingItemCount - 1, 0))
        return Self.trailingReserveBase
            + extraStructuralItems * Self.unmeasuredTrailingItemReserve
    }
}
