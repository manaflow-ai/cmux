public import Foundation

/// Where Home's split (``HomeSidebarSplitView``) puts its columns at a width: the list at the
/// person's width (``HomeSidebarWidth/clamp(_:window:minimum:transcriptMinimum:)``), the divider,
/// and the chat beside them; a lone conversation's list folds away (no column, no divider). One
/// rule for the split and for a bare launch's first frame (``HomeLaunchEarly``), which reserves
/// the same columns, so the message box sits where the page's will and nothing moves at the swap.
public struct HomeSplitColumns: Equatable, Sendable {
    /// The list's width; 0 while folded.
    public let list: CGFloat
    /// The divider's width; 0 while folded.
    public let divider: CGFloat
    public let folded: Bool

    /// The chat column's left edge.
    public var chatX: CGFloat { list + divider }

    /// - Parameters:
    ///   - width: The split's width.
    ///   - own: The list width to show: the saved one, else the standard.
    ///   - minimum: The list's minimum (avatars only).
    ///   - divider: The divider's thickness.
    ///   - holdsOneConversation: The list holds one conversation.
    ///   - loneRail: Debug Settings keeps a lone conversation's column.
    public init(width: CGFloat, own: CGFloat, minimum: CGFloat = HomeSidebarWidth.minimum, divider: CGFloat,
                holdsOneConversation: Bool, loneRail: Bool) {
        let clamped = HomeSidebarWidth.clamp(own, window: width - divider, minimum: minimum)
        // A list the person dragged to avatars keeps its column; a clamp to avatars of a lone
        // conversation's list takes none (visual QA 2026-10-21).
        folded = holdsOneConversation && HomeSidebarHeaderLayout.isCompact(width: clamped)
            && !HomeSidebarHeaderLayout.isCompact(width: own) && !loneRail
        list = folded ? 0 : clamped
        self.divider = folded ? 0 : divider
    }
}
