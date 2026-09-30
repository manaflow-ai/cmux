import Foundation

extension SidebarAutoGroupingInput {
    /// Reads the grouping facts for one live workspace, for one mode only.
    ///
    /// Only the active mode's dimension is read: Host mode never reads agent or
    /// unread state, and Status mode never touches the Observable cloud binding.
    /// The other dimension holds a neutral value (`.local` or `.terminals`)
    /// that no grouping of the given mode reads.
    @MainActor
    init(workspace: Workspace, mode: SidebarGroupByMode, unreadCount: (UUID) -> Int) {
        let host: SidebarAutoGroupingHost = mode == .host ? Self.host(for: workspace) : .local
        let status: SidebarAutoGroupingStatus
        if mode == .status {
            // Panel close removes its lifecycle entry, so no live-panel filter
            // is needed. Reading `panels` would also subscribe a SwiftUI body
            // to pane bookkeeping through Observation.
            status = SidebarAutoGroupingStatus(
                agentLifecycleStates: workspace.agentLifecycleStatesByPanelId.values.flatMap(\.values),
                unreadCount: unreadCount(workspace.id)
            )
        } else {
            status = .terminals
        }
        self.init(workspaceId: workspace.id, host: host, status: status)
    }

    @MainActor
    private static func host(for workspace: Workspace) -> SidebarAutoGroupingHost {
        if let vmID = workspace.cloudVMID {
            let name = workspace.cloudBindingState.machineNames[vmID]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .cloud(vmID: vmID, label: name?.isEmpty == false ? name : nil)
        }
        if let configuration = workspace.remoteConfiguration {
            return .remote(target: configuration.displayTarget)
        }
        // A remote tmux mirror has no remote configuration, but it lives on
        // the host its control connection attached to.
        if workspace.isRemoteTmuxMirror, let host = workspace.remoteTmuxSessionMirror?.host {
            return .remote(target: host.port.map { "\(host.destination):\($0)" } ?? host.destination)
        }
        return .local
    }
}
