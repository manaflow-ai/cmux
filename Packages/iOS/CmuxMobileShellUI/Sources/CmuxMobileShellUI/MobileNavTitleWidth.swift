import CoreGraphics

/// Width math for the leading glass nav-bar title pill, factored out so the
/// "use the available row without underlapping toolbar controls" rule is pure.
///
/// Workspace detail titles live in `.topBarLeading` beside the back button for
/// consistent placement between terminal and GUI modes. The cap only limits the
/// title's maximum width; the toolbar and glass button style keep their natural
/// height.
struct MobileNavTitleWidth {
    let contentWidth: CGFloat
    let hasBackButton: Bool
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
    /// Never shrink the pill below this, so a tiny pane still shows some title.
    static let floor: CGFloat = 96

    /// Max width for the leading title pill.
    var leadingCap: CGFloat {
        guard contentWidth > 0 else { return Self.unmeasuredFallback }
        let leading = hasBackButton ? Self.leadingReserve : 0
        let trailing = Self.trailingReserveBase + (hasChatToggle ? Self.chatToggleReserve : 0)
        return max(Self.floor, contentWidth - leading - trailing)
    }
}
