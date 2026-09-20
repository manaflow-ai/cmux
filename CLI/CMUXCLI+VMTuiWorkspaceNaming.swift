import Foundation

extension CMUXCLI.VMTuiOpenOptions {
    /// The title sent to local workspace creation, and whether it is a
    /// generated placeholder that may be replaced by the remote name.
    var workspaceTitle: (value: String, isGenerated: Bool) {
        let trimmed = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return (
                CMUXDiffViewerLocalization.string(
                    "workspace.cloudVM.defaultTitle",
                    defaultValue: "Cloud VM"
                ),
                true
            )
        }
        return (trimmed, false)
    }
}

extension CMUXCLI {
    /// Plain Cloud opens leave a creating card intact until its real terminal
    /// adopts it. Only the full TUI client needs a local command process.
    func prepareVMTuiTargetWorkspace(
        _ target: String, windowRaw: String?, fullClient: Bool,
        initialCommand: String, focus: Bool, client: SocketClient
    ) throws -> [String: Any] {
        guard fullClient else {
            return ["workspace_id": try resolveWorkspaceId(target, client: client, windowHandle: windowRaw)]
        }
        do {
            return try client.sendV2(
                method: "workspace.cloud_vm_terminal_ready",
                params: ["workspace_id": target, "initial_command": initialCommand, "focus": focus]
            )
        } catch let error as CLIError where error.message.contains("loading surface not found") {
            return ["workspace_id": target]
        }
    }

    /// Parameters shared by both Cloud bind calls. The generated title is
    /// metadata about the local placeholder, never an identity or a remote
    /// workspace name; explicit titles intentionally omit it.
    static func cloudWorkspaceBindingParameters(
        workspaceID: String,
        vmID: String,
        base: Bool,
        remoteWorkspaceID: String? = nil,
        generatedTitle: String?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "vm_id": vmID,
            "base": base,
        ]
        if let remoteWorkspaceID, !remoteWorkspaceID.isEmpty {
            params["remote_workspace_id"] = remoteWorkspaceID
        }
        if let generatedTitle, !generatedTitle.isEmpty {
            params["generated_title"] = generatedTitle
        }
        return params
    }
}
