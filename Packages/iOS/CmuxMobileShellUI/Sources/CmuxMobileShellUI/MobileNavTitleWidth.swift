import CoreGraphics

/// Width math for the centered glass nav-bar title pill, factored out so the
/// "grow the middle as much as possible" rule is pure and testable.
///
/// The title is a screen-centered `.principal` toolbar item, so it is bound by
/// TWICE the wider of the two side clusters (it grows symmetrically and hits the
/// nearer side first): the leading custom back button vs the trailing terminal
/// picker plus, when the visible tab has an agent session, the chat toggle.
/// Reserving only that (instead of a flat, over-large constant) lets a long
/// title use as much of the center as it safely can before truncating.
struct MobileNavTitleWidth {
    private init() {}

    /// Reserved width of the leading cluster: the custom back button (chevron +
    /// optional unread-count pill) plus the bar's leading margin.
    static let leadingReserve: CGFloat = 84
    /// Reserved width of the trailing cluster with just the terminal picker.
    static let trailingReserveBase: CGFloat = 60
    /// Extra width the agent-chat toggle adds to the trailing cluster.
    static let chatToggleReserve: CGFloat = 56
    /// Fallback before the pane width has been measured.
    static let unmeasuredFallback: CGFloat = 180
    /// Never shrink the pill below this, so a tiny pane still shows some title.
    static let floor: CGFloat = 96

    /// Max width for the centered title pill.
    /// - Parameters:
    ///   - contentWidth: Measured pane width (0 before first layout).
    ///   - hasChatToggle: Whether the trailing cluster includes the chat toggle.
    static func cap(contentWidth: CGFloat, hasChatToggle: Bool) -> CGFloat {
        guard contentWidth > 0 else { return unmeasuredFallback }
        let trailing = trailingReserveBase + (hasChatToggle ? chatToggleReserve : 0)
        let widerSide = max(leadingReserve, trailing)
        return max(floor, contentWidth - 2 * widerSide)
    }
}
