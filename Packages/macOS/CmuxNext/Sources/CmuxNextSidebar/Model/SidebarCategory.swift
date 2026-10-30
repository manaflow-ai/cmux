import Foundation

/// The home for every kind of thing that can reach the sidebar.
///
/// This is deliberately a taxonomy, not a new section or a default toggle. Existing
/// projections decide whether a category is visible; this type makes it impossible to
/// silently send a new item to an ungrouped bucket.
public nonisolated enum SidebarCategory: Hashable, Sendable {
    case home
    case workspace
    case group
    case browserTab
    case chat
    case app
    case fleetMachine
    case fleetSession
    case agentSession
    /// The existing local machine section is the safe home for a persisted kind
    /// introduced by a newer daemon before this client learns its richer placement.
    case localMachine
    case fold
    case custom
    case unknown

    /// Every persisted sidebar document body has an explicit home.
    public init(body: SidebarDocBody) {
        switch body {
        case .workspace: self = .workspace
        case .group: self = .group
        case .tab, .url: self = .browserTab
        case .builtin(let value): self = value == SidebarBuiltIn.home.rawValue ? .home : .app
        case .app: self = .app
        case .room: self = .chat
        case .savedGroup: self = .group
        // A reference has a document owner, so preserve that custom placement.
        case .ref: self = .custom
        // A newer persisted kind may have no placement metadata at all. The
        // reducer's existing fallback is this Mac's machine section; never make
        // an ungrouped row for it.
        case .other: self = .localMachine
        }
    }

    /// The existing destination for an acpmux lane. No new default surface is enabled.
    public static func lane(peer: String?, workspaceID: String?, parent: String?) -> Self {
        if peer != nil { return .fleetSession }
        if parent != nil || workspaceID != nil { return .agentSession }
        return .agentSession
    }

    public var isCategorized: Bool { self != .unknown }
}

/// Stable group keys used by existing machine, workspace and lineage projections.
public nonisolated enum SidebarLaneGroup: Hashable, Sendable {
    case fleet(String)
    case workspace(String)
    case lineage(String)
    case agent

    public static func forLane(peer: String?, workspaceID: String?, parent: String?, hasLiveParent: Bool = false) -> Self {
        if hasLiveParent, let parent { return .lineage(parent) }
        if let peer { return .fleet(peer) }
        if let workspaceID { return .workspace(workspaceID) }
        if let parent { return .lineage(parent) }
        return .agent
    }
}

