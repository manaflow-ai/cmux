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

/// A source of defaults for shared creation actions such as New Workspace and
/// New Terminal Surface.
///
/// Creation contexts are independent from workspaces. Selecting one changes
/// creation defaults; it does not filter, group, or own the workspace list.
/// The host supplies contexts in the user's saved order, with `Automatic`
/// fixed before the reorderable machine contexts.
public struct CmuxSidebarCreationContext: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var systemImageName: String
    public var kind: CmuxSidebarCreationContextKind
    public var isSelected: Bool
    public var workspaceCount: Int
    public var connectionState: String?

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        systemImageName: String,
        kind: CmuxSidebarCreationContextKind,
        isSelected: Bool,
        workspaceCount: Int = 0,
        connectionState: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImageName = systemImageName
        self.kind = kind
        self.isSelected = isSelected
        self.workspaceCount = workspaceCount
        self.connectionState = connectionState
    }
}
