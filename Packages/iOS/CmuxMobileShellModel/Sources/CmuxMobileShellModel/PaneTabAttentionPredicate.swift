/// The pure attention decision shared by pane tab-strip ordering and tests.
extension PaneTabStripCardSnapshot {
    /// Whether this card belongs in the attention partition.
    ///
    /// The exact predicate is: a mirrored terminal agent or injected chat card
    /// is waiting for user input (`agentStatus == .needsInput`) OR the layout
    /// DTO reports unread/bell activity (`hasUnread == true`). Running, idle,
    /// and unknown agents alone do not require attention.
    public var needsAttention: Bool {
        agentStatus == .needsInput || hasUnread
    }
}
