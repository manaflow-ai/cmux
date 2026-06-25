public import Foundation

/// One window row of a `system.top` / `system.memory` snapshot (the legacy
/// `v2TopWindowNode` dictionary, minus the coordinator-minted refs and the
/// process-annotation fields the nonisolated `system.top` pipeline adds
/// afterward).
///
/// The app target builds these from live `AppDelegate.MainWindowSummary` state
/// (carrying the already-built ``ControlSystemTopWorkspaceNode`` children); the
/// coordinator shapes them into the byte-faithful payload dictionary that the
/// worker-lane annotation pipeline then enriches, via
/// ``ControlCommandCoordinator/systemTopWindowPayload(_:)``.
public struct ControlSystemTopWindowNode: Sendable, Equatable {
    /// The window's identifier.
    public let windowID: UUID
    /// The window's index within the routed window enumeration.
    public let index: Int
    /// Whether this is the key window.
    public let isKeyWindow: Bool
    /// Whether the window is visible.
    public let isVisible: Bool
    /// The window's selected workspace identifier, if any.
    public let selectedWorkspaceID: UUID?
    /// The window's workspace nodes, in tab order.
    public let workspaces: [ControlSystemTopWorkspaceNode]

    /// Creates a window node.
    ///
    /// - Parameters:
    ///   - windowID: The window's identifier.
    ///   - index: The index within the routed window enumeration.
    ///   - isKeyWindow: Whether this is the key window.
    ///   - isVisible: Whether the window is visible.
    ///   - selectedWorkspaceID: The selected workspace identifier, if any.
    ///   - workspaces: The window's workspace nodes.
    public init(
        windowID: UUID,
        index: Int,
        isKeyWindow: Bool,
        isVisible: Bool,
        selectedWorkspaceID: UUID?,
        workspaces: [ControlSystemTopWorkspaceNode]
    ) {
        self.windowID = windowID
        self.index = index
        self.isKeyWindow = isKeyWindow
        self.isVisible = isVisible
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }
}
