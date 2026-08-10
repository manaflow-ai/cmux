/// How the aggregated multi-computer ("All Computers") workspace list orders
/// its rows.
///
/// Each Mac only owns its own sidebar order, so the cross-Mac order is a
/// per-device presentation choice with no shared source of truth. Raw values
/// are persisted by ``MobileWorkspaceSortStore``.
public enum MobileWorkspaceSortMode: String, CaseIterable, Codable, Sendable {
    /// Foreground computer first, remaining computers by display name. Each
    /// computer's workspaces keep the Mac's own sidebar order. The historical
    /// default.
    case automatic
    /// Computers in the user-chosen ``MobileWorkspaceSortStore/computerPriority``
    /// order first, remaining computers in `automatic` order. Each computer's
    /// workspaces keep the Mac's own sidebar order.
    case computerPriority
    /// One flat list across every computer, most recent activity first. Group
    /// sections cannot survive time interleaving, so this mode presents flat.
    case recentActivity
}
