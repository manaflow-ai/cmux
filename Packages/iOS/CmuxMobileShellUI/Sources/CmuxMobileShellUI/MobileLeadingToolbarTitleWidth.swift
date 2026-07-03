import CoreGraphics

/// Width math for the leading glass workspace title menu.
///
/// The workspace title belongs beside the back button, not in the centered
/// principal slot. Reserve the trailing toolbar cluster and the leading back
/// control so the title truncates before it can underlap native toolbar items.
struct MobileLeadingToolbarTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool

    static let backButtonReserve: CGFloat = 44
    static let trailingReserveBase: CGFloat = 64
    static let chatToggleReserve: CGFloat = 60
    static let barMarginsAndSpacing: CGFloat = 84
    static let unmeasuredFallback: CGFloat = 140
    static let maximumMeasuredCap: CGFloat = unmeasuredFallback
    static let floor: CGFloat = 96

    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = hasBackButton ? Self.backButtonReserve : 0
        let trailing = hasTrailingCluster
            ? Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
            : 0
        let measuredCap = max(0, contentWidth - leading - trailing - Self.barMarginsAndSpacing)
        return min(Self.maximumMeasuredCap, measuredCap)
    }
}
