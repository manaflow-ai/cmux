/// `tabs.hoverPreviews` (Leo 2026-10-14): what resting on a tab shows.
public nonisolated enum TabHoverPreviews: String, Sendable, CaseIterable, Codable {
    /// No card.
    case off
    /// The title and the tab's facts (where, state, memory), no thumbnail.
    case compact
    /// The facts and a thumbnail of the tab (the default: the card has always had one).
    case full
}
