import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import CmuxCore

extension Workspace {
    /// CLI status is derived from the same carrier and graph as native panes.
    func tuiSSHStatusPayload() -> [String: Any] {
        guard let configuration = remoteConfiguration else { return [:] }
        let connection = SSHTuiConnection(configuration: configuration)
        let machine = SurfaceMachineID(rawValue: connection.id)
        let catalog = SurfaceCatalog.shared
        let info = catalog.machineInfo(for: machine)
        let connected = info?.linkState == .connected
        let state: String
        switch info?.linkState {
        case .connected?: state = "connected"
        case .connecting?: state = "connecting"
        case .error?: state = "error"
        default: state = remoteConnectionState.rawValue
        }
        let resources = catalog.authoritativeSnapshot.resources(on: machine)
        return [
            "enabled": true, "backend": "cmux-tui", "transport": "ssh", "terminal_transport": "ssh",
            "machine": machine.rawValue, "state": state, "connected": connected,
            "destination": configuration.destination, "port": configuration.port ?? NSNull(),
            "has_identity_file": configuration.identityFile != nil, "has_ssh_options": !configuration.sshOptions.isEmpty,
            "terminal_profile": configuration.terminalProfile.kind.rawValue,
            "terminal_tmux_session": configuration.terminalProfile.tmuxSessionName ?? NSNull(),
            "remote_workspace_id": cloudVMBinding?.remoteWorkspaceID ?? NSNull(),
            "active_terminal_sessions": catalog.projections.filter { $0.workspaceID == id && $0.resource.machine == machine }.count,
            "daemon": ["state": connected ? "ready" : state, "name": "cmux-tui"],
            "detail": info?.linkError ?? remoteConnectionDetail ?? NSNull(),
            "detected_ports": resources.compactMap(\.port), "forwarded_ports": [Int](), "conflicted_ports": [Int](),
            "proxy": ["state": "on_demand", "transport": "cmux-tui"],
        ]
    }
}
