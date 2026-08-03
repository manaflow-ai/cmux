public import CmuxExtensionKit

/// One host-provided execution context exposed to interpreted custom sidebars.
///
/// Contexts influence creation defaults. They do not own or filter workspaces,
/// so a custom sidebar can present them in any navigation arrangement.
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
        self.connectionState = connectionState
        self.childColumn = childColumn ?? .sharedWorkspaces(parentID: id)
    }
}
