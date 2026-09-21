import Foundation

/// Selects the filesystem used by both the sidebar and its Files/Find panes.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    /// Builds the root request shared by the main sidebar and tool panes.
    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        if let binding = workspace.cloudVMBinding {
            let managedPolicyEnabled = ManagedCloudPolicy.isEnabled
            let featureEnabled = CloudMachinesFeature.isEnabled
            let policyEnabled = managedPolicyEnabled && featureEnabled
            let provider = CmuxTuiSurfaceProviderRegistry.shared.provider(machineID: binding.vmID)
            let connected = provider?.info.linkState == .connected
            let detail: String?
            if !managedPolicyEnabled {
                detail = ManagedCloudPolicy.disabledMessage
            } else if !featureEnabled {
                detail = CloudMachinesFeature.disabledMessage
            } else if !connected {
                detail = provider?.info.linkError ?? String(localized: "fileExplorer.status.cloudDisconnected", defaultValue: "Cloud machine is not connected")
            } else {
                detail = nil
            }
            return .remoteCloud(
                workspaceId: workspace.id,
                vmID: binding.vmID,
                displayTarget: binding.vmID,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: policyEnabled && connected,
                unavailableDetail: detail
            )
        }
        if workspace.usesRemoteDirectoryProvenance {
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else { return .none }
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(
                    destination: configuration.destination,
                    port: configuration.port,
                    identityFile: configuration.identityFile,
                    sshOptions: configuration.sshOptions
                ),
                displayTarget: configuration.displayTarget,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: workspace.remoteConnectionState == .connected,
                unavailableDetail: workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            )
        }
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? .none : .local(workspaceId: workspace.id, path: path)
    }
}
