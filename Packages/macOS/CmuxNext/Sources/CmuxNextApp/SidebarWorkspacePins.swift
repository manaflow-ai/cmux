import CmuxNextActions
import CmuxNextSidebar

/// The sidebar model's pin hook (`SidebarModel.workspacePin`): the workspace's
/// pin state and Pin/Unpin Workspace, the action the palette, the row menu and
/// the CLI run (`PinCommands`: a layout tile or the daemon flag). Rows no longer
/// draw a hover pin from it (Lawrence 2026-10-21).
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
