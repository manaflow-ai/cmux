import CmuxControlSocket
import Foundation

/// Live ownership gate for a relay read that resolves through a Dock store.
/// Global/window Docks are local surfaces and can never be remote-relay targets.
extension TerminalController {
    @MainActor
    func remoteRelayDockReadIsCurrent(
        routing: ControlRoutingSelectors,
        dock: DockSplitStore,
        surfaceID: UUID
    ) -> Bool {
        guard routing.remoteRelayOwnerWorkspaceID != nil else { return true }
        guard dock.scope == .workspace,
              dock.workspaceId == routing.remoteRelayOwnerWorkspaceID,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: dock.workspaceId) else {
            return false
        }
        return remoteRelayTargetIsCurrent(routing: routing, workspace: workspace, surfaceID: surfaceID)
    }
}
