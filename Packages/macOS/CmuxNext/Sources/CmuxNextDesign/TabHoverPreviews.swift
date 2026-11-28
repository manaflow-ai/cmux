/// What a tab's hover card shows (Leo 2026-10-14): a Debug Settings tunable,
/// `TabTunables.hoverPreviews`, until the persisted `tabs.hoverPreviews` setting
/// lands after the settings freeze. Whether cards open at all, and after how
/// long, is `sidebar.hoverCards.enabled` and `.delay` (cx-23e1f).
public nonisolated enum TabHoverPreviews: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// The title and the tab's facts (where, state, memory), no thumbnail.
    case compact
    /// The facts and a thumbnail of the tab (the default: the card has always had one).
    case full

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact (no thumbnail)"
        case .full: "Full (with thumbnail)"
        }
    }
}
