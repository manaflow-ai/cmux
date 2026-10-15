/// `tabs.hoverPreviews` (Leo 2026-10-14): what a tab's hover card shows. Whether cards open at
/// all, and after how long, is `sidebar.hoverCards.enabled` and `.delay` (cx-23e1f).
public nonisolated enum TabHoverPreviews: String, Sendable, CaseIterable, Codable {
    /// The title and the tab's facts (where, state, memory), no thumbnail.
    case compact
    /// The facts and a thumbnail of the tab (the default: the card has always had one).
    case full
}
