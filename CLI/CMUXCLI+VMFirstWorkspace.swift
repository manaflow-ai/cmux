import Foundation

extension CMUXCLI {
    /// The full TUI owns its local pane, so prepare only the remote starter
    /// before launching the client. The ordinary native view uses the same
    /// surface.new_terminal request while creating its local projection.
    func prepareVMTuiFirstWorkspace(vmId: String, client: SocketClient) throws {
        let catalog = try client.sendV2(
            method: "surface.catalog",
            params: ["machine": vmId, "ensure_linked": true], responseTimeout: 180
        )
        switch VMRemoteWorkspaceResolver().resolveVMMachineTerminal(machine: vmId, catalog: catalog) {
        case .resolved:
            return
        case .empty(let remoteWorkspaceID):
            var params: [String: Any] = [
                "machine": vmId, "open": false, "initial_workspace": true,
                "suppress_welcome": ProcessInfo.processInfo.environment["CMUX_CLOUD_WELCOME"] == "0"
            ]
            if let remoteWorkspaceID { params["remote_workspace_id"] = remoteWorkspaceID }
            _ = try client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 180)
        case .unavailable:
            throw CLIError(message: String(localized: "cli.vm.open.sessionsUnavailable", defaultValue: "The machine’s sessions are unavailable. Refresh and retry."))
        }
    }
}
