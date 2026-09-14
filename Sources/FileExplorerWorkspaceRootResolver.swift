import Foundation

/// Selects the filesystem used by both the sidebar and its Files/Find panes.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    /// Builds the root request shared by the main sidebar and tool panes.
    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        if let binding = workspace.cloudVMBinding {
            return .remoteCloud(
                workspaceId: workspace.id,
                vmID: binding.vmID,
                displayTarget: binding.vmID,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: ManagedCloudPolicy.isEnabled,
                unavailableDetail: ManagedCloudPolicy.isEnabled ? nil : ManagedCloudPolicy.disabledMessage
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
