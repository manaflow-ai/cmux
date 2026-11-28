import Foundation

// `terminal.project` (resource API v2) request and result shapes.

/// `MutationResult<T>`: the flat `{value, generation, revision, replayed}`.
public struct ResourceMutationResult<Value: Decodable & Sendable>: Decodable, Sendable {
    public var value: Value
    public var generation: String?
    /// Decimal string cursor revision.
    public var revision: String?
    public var replayed: Bool?
}

/// A pane named by its durable resource ids, as `terminal.project` needs
/// (workspace, screen, and pane are all required destination selectors).
public struct PaneResourcePath: Sendable, Hashable {
    public var workspace: ResourceID
    public var screen: ResourceID
    public var pane: ResourceID

    public init(workspace: ResourceID, screen: ResourceID, pane: ResourceID) {
        self.workspace = workspace
        self.screen = screen
        self.pane = pane
    }
}

/// `TabSnapshot` fields a projection returns: the new view's tab id.
public struct ProjectedTab: Decodable, Sendable, Equatable {
    /// The new tab resource id (`tab_…`), the tab's `tab_resource_id`.
    public var id: ResourceID
    public var paneID: ResourceID?
    public var index: Int?

    enum CodingKeys: String, CodingKey {
        case id, index
        case paneID = "pane_id"
    }
}
