public import Foundation

/// What a cloud group link (`cmux://group/grp_…[/workspace/ws_…]`, plans/cmux-next/cloud-groups-DESIGN.md
/// slice 1) opens on this Mac, decided from the group's record and the workspaces open here
/// (the App's CloudGroupLink reads the record and shows the workspace).
nonisolated extension DeepLink {
    /// What opening the group does, decided from its record and the workspaces open here.
    public enum GroupPlan: Equatable, Sendable {
        /// Show this workspace (a `ws_` resource id open on this Mac).
        case reveal(String)
        /// The group exists but none of its workspaces is open on this Mac.
        case notOpenHere
        /// The group is missing, or the account is not a member.
        case gone
    }

    /// The workspace a link opens: the named workspace when it is in the group and open here,
    /// else the group's items in position order, the first open here.
    ///
    /// - Parameters:
    ///   - reply: `group.get`'s value (`{group, items: [{workspace, position, …}]}`), nil when the read refused.
    ///   - named: The link's `/workspace/<ws_…>`, if any.
    ///   - openHere: Whether a `ws_` id is open on this Mac.
    public static func groupPlan(reply: [String: Any]?, named: String?, openHere: (String) -> Bool) -> GroupPlan {
        guard let reply, reply["group"] is [String: Any] else { return .gone }
        let items = (reply["items"] as? [[String: Any]] ?? [])
            .compactMap { item -> (String, Int)? in
                guard let ws = item["workspace"] as? String else { return nil }
                return (ws, (item["position"] as? NSNumber)?.intValue ?? Int.max)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        if let named, items.contains(named), openHere(named) { return .reveal(named) }
        if let first = items.first(where: openHere) { return .reveal(first) }
        return .notOpenHere
    }
}
