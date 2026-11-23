import CmuxNextActions
import CmuxNextSidebar

/// A row's pin state (a pinned row offers no hover close) and its Pin/Unpin Workspace toggle. The hover pin went
/// (dp-1824f397ce: Pin and Unpin live in the right-click menu); the toggle runs the palette's, menu's and CLI's Pin/Unpin Workspace (`PinCommands`) on that row alone
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
