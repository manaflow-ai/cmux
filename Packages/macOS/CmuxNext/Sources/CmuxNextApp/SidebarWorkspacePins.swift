import CmuxNextActions
import CmuxNextSidebar

/// A row's pin state (a pinned row offers no hover close) and Pin/Unpin Workspace toggle (right-click menu; the hover pin went,
/// dp-1824f397ce); it runs `PinCommands` on that row alone (`closesRowOnly`; Leo 2026-11-22, "the pin button ... doesnt do anything").
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
