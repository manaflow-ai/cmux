/// The pure attention decision shared by pane tab-strip ordering and tests.
public struct PaneTabAttentionPredicate: Sendable {
    private init() {}

    /// Returns whether a card belongs in the attention partition.
    ///
    /// The exact predicate is: a mirrored terminal agent or injected chat card
    /// is waiting for user input (`agentStatus == .needsInput`) OR the layout
    /// DTO reports unread/bell activity (`hasUnread == true`). Running, idle,
    /// and unknown agents alone do not require attention.
    /// - Parameter card: The immutable strip card to classify.
    /// - Returns: `true` only when the card meets the documented predicate.
    public static func needsAttention(_ card: PaneTabStripCardSnapshot) -> Bool {
        card.agentStatus == .needsInput || card.hasUnread
    }
}
