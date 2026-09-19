import Foundation

/// The host-defined behavior represented by a creation context.
public enum CmuxSidebarCreationContextKind: String, Codable, Equatable, Sendable {
    /// Preserve the behavior of the action's current workspace.
    case automatic
    /// Create a local workspace or terminal surface.
    case local
    /// Create a workspace or terminal surface using a remote's defaults.
    case remote
}

/// Optional actions the host can perform for one creation context.
public enum CmuxSidebarCreationContextCapability: String, Codable, Equatable, Hashable, Sendable {
    case attachRemoteCmuxTUI
}

/// A source of defaults for shared creation actions such as New Workspace and
/// New Terminal Surface.
///
/// A context owns one child workspace collection while remaining independent
/// from runtime locality. A local workspace can belong to a remote context,
/// and any workspace can mix local and remote surfaces. The host supplies
/// contexts in the user's saved order, with `Automatic` fixed before the
/// reorderable machine contexts as an aggregate route.
public struct CmuxSidebarCreationContext: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case systemImageName
        case kind
        case isSelected
        case workspaceCount
        case workspaceIDs
        case focusedWorkspaceID
        case capabilities
        case connectionState
        case childColumn
    }

    public var id: String
    public var title: String
    public var detail: String?
    public var systemImageName: String
    public var kind: CmuxSidebarCreationContextKind
    public var isSelected: Bool
    public var workspaceCount: Int
    /// Ordered workspace children owned by this route. Automatic contains the
    /// aggregate list.
    public var workspaceIDs: [UUID]
    /// Last focused child for this context in the containing cmux window.
    public var focusedWorkspaceID: UUID?
    public var capabilities: Set<CmuxSidebarCreationContextCapability>
    public var connectionState: String?
    /// The parent-specific route rendered in the column after this context.
    public var childColumn: CmuxSidebarChildColumn

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        systemImageName: String,
        kind: CmuxSidebarCreationContextKind,
        isSelected: Bool,
        workspaceCount: Int = 0,
        workspaceIDs: [UUID] = [],
        focusedWorkspaceID: UUID? = nil,
        capabilities: Set<CmuxSidebarCreationContextCapability> = [],
        connectionState: String? = nil,
        childColumn: CmuxSidebarChildColumn? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImageName = systemImageName
        self.kind = kind
        self.isSelected = isSelected
        self.workspaceCount = workspaceCount
        self.workspaceIDs = workspaceIDs
        self.focusedWorkspaceID = focusedWorkspaceID
        self.capabilities = capabilities
        self.connectionState = connectionState
        self.childColumn = childColumn ?? .sharedWorkspaces(parentID: id)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        systemImageName = try container.decode(String.self, forKey: .systemImageName)
        kind = try container.decode(CmuxSidebarCreationContextKind.self, forKey: .kind)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        workspaceCount = try container.decodeIfPresent(Int.self, forKey: .workspaceCount) ?? 0
        workspaceIDs = try container.decodeIfPresent([UUID].self, forKey: .workspaceIDs) ?? []
        focusedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .focusedWorkspaceID)
        capabilities = try container.decodeIfPresent(
            Set<CmuxSidebarCreationContextCapability>.self,
            forKey: .capabilities
        ) ?? []
        connectionState = try container.decodeIfPresent(String.self, forKey: .connectionState)
        childColumn = try container.decodeIfPresent(
            CmuxSidebarChildColumn.self,
            forKey: .childColumn
        ) ?? .sharedWorkspaces(parentID: id)
    }
}
