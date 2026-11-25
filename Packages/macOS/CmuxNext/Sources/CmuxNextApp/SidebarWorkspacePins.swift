import CmuxNextActions
import CmuxNextSidebar

/// An expanded row's hover pin (cx-13w3): the row reads the workspace's pin
/// state and runs Pin/Unpin Workspace on it, the action the palette, the
/// row menu and the CLI run (`PinCommands`: a layout tile or the daemon flag).
@MainActor
enum SidebarWorkspacePins {
    static func wire(_ bridge: SidebarBridge) {
        bridge.model.workspacePin = (
            isPinned: { [weak bridge] id in
                guard let bridge, let workspace = bridge.services.workspace(id: id.rawValue) else { return false }
                return PinCommands(context: AppActionContext(services: bridge.services)).isWorkspacePinned(workspace)
            },
            toggle: { [weak bridge] id in
                let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id.rawValue), origin: .user)
                _ = bridge?.services.registry.perform("palette.toggleWorkspacePin", invocation: invocation)
            }
        )
    }
}
