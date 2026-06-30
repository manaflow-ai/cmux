import CoreGraphics

/// Width math for the leading glass workspace title pill, factored out so the
/// "grow until the trailing chrome would overlap" rule is pure and testable.
///
/// The title lives in the same leading toolbar item as the custom back button.
/// Its cap therefore reserves the leading margin/back button once and the
/// trailing terminal picker/chat controls once. It must not use centered
/// principal-title math, because that lets SwiftUI re-own placement and pull the
/// title away from the back button.
struct MobileNavTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool

    /// Left edge margin inside the navigation bar.
    static let leadingMargin: CGFloat = 16
    /// Custom back button reserve: chevron + optional unread-count pill.
    static let backButtonReserve: CGFloat = 58
    /// Space between the back button glass and title glass.
    static let interControlSpacing: CGFloat = 8
    /// Reserved width of the trailing cluster with just the terminal picker.
    static let trailingReserveBase: CGFloat = 60
    /// Extra width the agent-chat toggle adds to the trailing cluster.
    static let chatToggleReserve: CGFloat = 56
    /// Gap between the leading title pill and trailing controls.
    static let trailingSafetyGap: CGFloat = 12
    /// Fallback before the pane width has been measured.
    static let unmeasuredFallback: CGFloat = 180
    /// Preferred minimum width when the safe leading slot can fit it.
    static let floor: CGFloat = 96

    /// Max safe width for the leading title pill.
    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = Self.leadingMargin
            + (hasBackButton ? Self.backButtonReserve + Self.interControlSpacing : 0)
        let trailing = hasTrailingCluster
            ? Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
            : 0
        return max(0, contentWidth - leading - trailing - Self.trailingSafetyGap)
    }
}
