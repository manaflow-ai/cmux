import Foundation

@MainActor
struct FileExplorerWorkspaceRootResolver {
    func resolve(
        workspace: Workspace,
        detectedSSHSession: DetectedSSHSession?
    ) -> FileExplorerWorkspaceRoot {
        if workspace.usesRemoteDirectoryProvenance {
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else {
                return .none
            }
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

        if let detectedSSHSession {
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(detectedSSHSession: detectedSSHSession),
                displayTarget: detectedSSHSession.destination,
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil
            )
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            return .none
        }
        return .local(workspaceId: workspace.id, path: directory)
    }
}
