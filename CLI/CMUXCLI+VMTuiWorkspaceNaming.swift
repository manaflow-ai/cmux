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
