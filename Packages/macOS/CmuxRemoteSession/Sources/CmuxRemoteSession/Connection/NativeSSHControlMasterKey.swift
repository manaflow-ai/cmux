internal import CmuxCore
internal import CmuxFoundation

/// Identifies one cmux-owned OpenSSH master across workspace relay identities.
struct NativeSSHControlMasterKey: Hashable, Sendable {
    let unresolvedConnection: NativeSSHConnectionKey?
    let controlPath: String

    init?(
        configuration: WorkspaceRemoteConfiguration,
        sharingOptions: SSHConnectionSharingOptions
    ) {
        guard configuration.transport == .ssh,
              let controlPath = sharingOptions.cmuxOwnedControlPath(in: configuration.sshOptions) else {
            return nil
        }
        self.unresolvedConnection = controlPath.contains("%")
            ? NativeSSHConnectionKey(
                configuration: configuration,
                sharingOptions: sharingOptions
            )
            : nil
        self.controlPath = controlPath
    }
}
