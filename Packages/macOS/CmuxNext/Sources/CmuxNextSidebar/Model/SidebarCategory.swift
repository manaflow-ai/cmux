import Foundation

/// The home for every kind of thing that can reach the sidebar.
///
/// This is deliberately a taxonomy, not a new section or a default toggle. Existing
/// projections decide placement and visibility. The exhaustive switch (no default) is the
/// compile-time gate: adding a SidebarDocBody case requires an explicit category here.
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
    /// The local machine category for an unfamiliar body. Persisted document items must
    /// still carry a section; this taxonomy never overrides their stored placement.
    case localMachine
    case fold
    case custom

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
        // Unknown bodies use the local category, while the document's required
        // section continues to control their actual placement.
        case .other: self = .localMachine
        }
    }

    /// The existing destination for an acpmux lane. No new default surface is enabled.
    public static func lane(peer: String?) -> Self {
        peer == nil ? .agentSession : .fleetSession
    }
}

