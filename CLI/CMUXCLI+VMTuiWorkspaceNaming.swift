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
    static func remoteWorkspaceName(
        _ workspaceID: String,
        machine: String,
        in catalog: [String: Any]
    ) -> String? {
        VMRemoteWorkspaceResolver().remoteWorkspaceName(workspaceID, machine: machine, in: catalog)
    }

    /// Parameters shared by both Cloud bind calls. The generated title identifies
    /// the local optimistic placeholder; the optional remote name is an accepted
    /// daemon label used to adopt that placeholder without a later name flash.
    static func cloudWorkspaceBindingParameters(
        workspaceID: String,
        vmID: String,
        base: Bool,
        remoteWorkspaceID: String? = nil,
        generatedTitle: String?,
        remoteWorkspaceName: String? = nil
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
        if let remoteWorkspaceName, !remoteWorkspaceName.isEmpty {
            params["remote_workspace_name"] = remoteWorkspaceName
        }
        return params
    }
}
