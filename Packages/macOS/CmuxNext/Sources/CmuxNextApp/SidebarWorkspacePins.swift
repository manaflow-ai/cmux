import CmuxNextActions
import CmuxNextSidebar

/// A row's hover pin (cx-13w3): runs the palette's, menu's and CLI's Pin/Unpin Workspace (`PinCommands`) on that row alone
/// (`closesRowOnly`; Leo 2026-11-22, "the pin button ... doesnt do anything": it pinned the window's selection).
@MainActor
enum SidebarWorkspacePins {
    static func wire(_ bridge: SidebarBridge) {
        bridge.model.workspacePin = (
            isPinned: { [weak bridge] id in
                guard let bridge, let workspace = bridge.services.workspace(id: id.rawValue) else { return false }
                return PinCommands(context: AppActionContext(services: bridge.services)).isWorkspacePinned(workspace)
            },
            toggle: { [weak bridge] id in
                var invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id.rawValue), origin: .user)
                invocation.closesRowOnly = true
                _ = bridge?.services.registry.perform("palette.toggleWorkspacePin", invocation: invocation)
            }
        )
    }
}
