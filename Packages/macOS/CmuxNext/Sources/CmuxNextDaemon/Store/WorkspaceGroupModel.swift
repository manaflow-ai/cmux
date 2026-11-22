import Foundation
public import Observation

/// One sidebar section.
@Observable @MainActor
public final class WorkspaceGroupModel: Identifiable {
    public let id: WorkspaceGroupID
    public internal(set) var name: String
    public internal(set) var color: String?
    public internal(set) var collapsed: Bool
    public internal(set) var index: Int
    /// The personal row index the group shows right before; nil after
    /// every loose workspace (`personal-mixed-order-v1`).
    public internal(set) var topIndex: Int?
    /// One emoji or an SF Symbol name (`workspace-group-icon-v1`).
    public internal(set) var icon: String?
    /// Pinned (saved) group (`workspace-group-pin-v1`).
    public internal(set) var pinned: Bool

    init(_ s: WorkspaceGroupSnapshot) {
        id = s.id
        name = s.name
        color = s.color
        collapsed = s.collapsed
        index = s.index
        topIndex = s.topIndex
        icon = s.icon
        pinned = s.pinned
    }

    func update(_ s: WorkspaceGroupSnapshot) {
        if name != s.name { name = s.name }
        if color != s.color { color = s.color }
        if collapsed != s.collapsed { collapsed = s.collapsed }
        if index != s.index { index = s.index }
        if topIndex != s.topIndex { topIndex = s.topIndex }
        if icon != s.icon { icon = s.icon }
        if pinned != s.pinned { pinned = s.pinned }
    }

    func setCollapsed(_ value: Bool) { if collapsed != value { collapsed = value } }
}

/// Sidebar flattening: ungrouped workspaces first, then each group in order
/// with its members in workspace order. Cached on the store and recomputed
/// only when order, membership, or groups change.
public struct SidebarSection: Identifiable {
    /// nil for the ungrouped section.
    public let group: WorkspaceGroupModel?
    public let workspaces: [WorkspaceModel]

    public init(group: WorkspaceGroupModel?, workspaces: [WorkspaceModel]) {
        self.group = group
        self.workspaces = workspaces
    }

    public var id: String { group?.id.rawValue ?? "" }
}
