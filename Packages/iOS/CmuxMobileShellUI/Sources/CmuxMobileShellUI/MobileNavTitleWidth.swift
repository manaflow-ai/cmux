import CoreGraphics

/// Width math for the centered glass nav-bar title pill, factored out so the
/// "grow the middle as much as possible" rule is pure and testable.
///
/// The title is a screen-centered `.principal` toolbar item, so it is bound by
/// TWICE the wider of the two visible side clusters (the leading custom back
/// button vs. the trailing terminal picker plus, when present, the chat toggle).
/// Reserving only the visible side chrome lets a long title use as much of the
/// center as it safely can before truncating.
struct MobileNavTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool

    /// Reserved width of the leading cluster: the custom back button (chevron +
    /// optional unread-count pill) plus the bar's leading margin.
    static let leadingReserve: CGFloat = 84
    /// Reserved width of the trailing cluster with just the terminal picker.
    static let trailingReserveBase: CGFloat = 60
    /// Extra width the agent-chat toggle adds to the trailing cluster.
    static let chatToggleReserve: CGFloat = 56
    /// Fallback before the pane width has been measured.
    static let unmeasuredFallback: CGFloat = 180
    /// Preferred minimum width when the safe centered slot can fit it.
    static let floor: CGFloat = 96

    /// Max safe width for the centered title pill.
    var cap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = hasBackButton ? Self.leadingReserve : 0
        let trailing = hasTrailingCluster
            ? Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
            : 0
        let widerSide = max(leading, trailing)
        return max(0, contentWidth - 2 * widerSide)
    }
}
