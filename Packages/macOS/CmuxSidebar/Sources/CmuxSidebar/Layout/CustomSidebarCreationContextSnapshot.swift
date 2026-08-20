public import CmuxExtensionKit
public import Foundation

/// One host-provided execution context exposed to interpreted custom sidebars.
///
/// Contexts own child workspace collections without constraining where those
/// workspaces or their surfaces execute.
public struct CustomSidebarCreationContextSnapshot: Sendable, Equatable {
    /// Stable identifier passed to `sidebar.creation_context.select`.
    public let id: String
    /// User-facing context name.
    public let title: String
    /// Optional secondary status or endpoint text.
    public let subtitle: String?
    /// SF Symbol suggested by the host.
    public let systemImageName: String
    /// Whether this context currently supplies creation defaults.
    public let isSelected: Bool
    /// Host-defined context kind (`automatic`, `local`, or `remote`).
    public let kind: String
    /// Number of open workspaces currently using this context.
    public let workspaceCount: Int
    /// Ordered workspace children owned by this context.
    public let workspaceIDs: [UUID]
    /// Last focused child for this context in the containing cmux window.
    public let focusedWorkspaceID: UUID?
    /// Host actions supported by this context.
    public let capabilities: [String]
    /// Remote connection state, when the context represents a remote.
    public let connectionState: String?
    /// Parent-owned route to the column rendered after this context.
    public let childColumn: CmuxSidebarChildColumn

    /// Creates an immutable creation-context snapshot.
    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImageName: String,
        isSelected: Bool,
        kind: String,
        workspaceCount: Int = 0,
        workspaceIDs: [UUID] = [],
        focusedWorkspaceID: UUID? = nil,
        capabilities: [String] = [],
        connectionState: String? = nil,
        childColumn: CmuxSidebarChildColumn? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.isSelected = isSelected
        self.kind = kind
        self.workspaceCount = workspaceCount
        self.workspaceIDs = workspaceIDs
        self.focusedWorkspaceID = focusedWorkspaceID
        self.capabilities = capabilities
        self.connectionState = connectionState
        self.childColumn = childColumn ?? .sharedWorkspaces(parentID: id)
    }
}
