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
    /// Retain the exact first workspace before attachment can fail. The next
    /// open reuses this binding even when another workspace gained daemon focus.
    func bindVMTuiInitialWorkspace(
        _ workspaceID: String, machine: String, remoteWorkspaceID: String,
        base: Bool, client: SocketClient
    ) throws {
        _ = try client.sendV2(method: "workspace.cloud_vm_bind", params: Self.cloudWorkspaceBindingParameters(
            workspaceID: workspaceID, vmID: machine, base: base,
            remoteWorkspaceID: remoteWorkspaceID, generatedTitle: nil
        ))
    }

    /// Plain Cloud opens leave a creating card intact until its real terminal
    /// adopts it. Only the full TUI client needs a local command process.
    func prepareVMTuiTargetWorkspace(
        _ target: String, windowRaw: String?, fullClient: Bool,
        initialCommand: String, focus: Bool, client: SocketClient
    ) throws -> [String: Any] {
        guard fullClient else {
            let workspaceID = try resolveWorkspaceId(target, client: client, windowHandle: windowRaw)
            var windows: [String] = []
            if let windowRaw, !windowRaw.isEmpty { windows.append(windowRaw) }
            if let listed = try? client.sendV2(method: "window.list") {
                let all = (listed["windows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                windows.append(contentsOf: all.filter { !windows.contains($0) })
            }
            for windowID in windows {
                guard let listed = try? client.sendV2(method: "workspace.list", params: ["window_id": windowID]) else { continue }
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                if let item = items.first(where: { ($0["id"] as? String) == workspaceID }) {
                    var receipt = item
                    receipt["workspace_id"] = workspaceID
                    receipt["window_id"] = item["window_id"] ?? windowID
                    return receipt
                }
            }
            let receipt: [String: Any] = ["workspace_id": workspaceID]
            return receipt
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
