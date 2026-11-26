public import Foundation

/// The `extension.sidebar.snapshot` snapshot the app side hands the
/// coordinator: the event-bus sequence plus the routed window's workspaces.
public struct ControlExtensionSidebarSnapshot: Sendable, Equatable {
    /// The event bus's latest sequence, clamped to `>= 0`.
    public let sequence: Int
    /// The routed window's identifier, if it resolved.
    public let windowID: UUID?
    /// The routed window's selected workspace, if any.
    public let selectedWorkspaceID: UUID?
    /// The window's workspace rows, in tab order.
    public let workspaces: [ControlExtensionSidebarWorkspace]

    /// Creates a sidebar snapshot.
    ///
    /// - Parameters:
    ///   - sequence: The event bus's latest sequence.
    ///   - windowID: The routed window's identifier, if any.
    ///   - selectedWorkspaceID: The selected workspace, if any.
    ///   - workspaces: The workspace rows.
    public init(
        sequence: Int,
        windowID: UUID?,
        selectedWorkspaceID: UUID?,
        workspaces: [ControlExtensionSidebarWorkspace]
    ) {
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }
}
