import CmuxControlSocket
import CmuxSidebar
import Foundation

/// Routes a web sidebar's focus request onto the app's shared workspace-select path.
///
/// The sidebar package knows nothing about windows, tab managers, or which window owns a workspace,
/// and it should not: that resolution already exists once, behind
/// `TerminalController.controlSelectWorkspace`, which the socket's `workspace.select` also goes
/// through. Reusing it is what makes a click in an HTML sidebar select a workspace in *another*
/// window and bring that window forward — one native call, the same behaviour every other
/// entrypoint gets, with no socket string in the middle.
///
/// Routing carries only the workspace id, so the owning window is discovered from the workspace
/// itself rather than assumed to be the one the sidebar is mounted in.
@MainActor
struct CustomSidebarWorkspaceFocusRouter {
    private let selectWorkspace:
        @MainActor (ControlRoutingSelectors, UUID) -> ControlWorkspaceRoutedResolution

    /// Creates a router over an arbitrary select implementation.
    ///
    /// - Parameter selectWorkspace: Performs the routed selection. Injected so a test can drive the
    ///   mapping without a live window graph.
    init(
        selectWorkspace: @escaping @MainActor (ControlRoutingSelectors, UUID)
            -> ControlWorkspaceRoutedResolution
    ) {
        self.selectWorkspace = selectWorkspace
    }

    /// Creates a router over the app's shared control-workspace path.
    ///
    /// - Parameter controller: The controller whose `controlSelectWorkspace` the socket also drives.
    init(controller: TerminalController) {
        self.init { routing, workspaceID in
            controller.controlSelectWorkspace(routing: routing, workspaceID: workspaceID)
        }
    }

    /// Selects a workspace by id and reports the outcome in the sidebar's vocabulary.
    ///
    /// - Parameter workspaceID: The workspace the page asked for.
    /// - Returns: The status to reply to the page with.
    func focus(_ workspaceID: UUID) -> CustomSidebarFocusStatus {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
        switch selectWorkspace(routing, workspaceID) {
        case .resolved:
            return .focused
        case .notFound:
            return .notFound
        case .tabManagerUnavailable:
            return .unavailable
        }
    }
}
