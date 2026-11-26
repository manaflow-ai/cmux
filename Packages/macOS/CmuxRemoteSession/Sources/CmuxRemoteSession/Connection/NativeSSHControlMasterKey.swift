internal import CmuxCore
internal import CmuxFoundation

/// Identifies one cmux-owned OpenSSH master across workspace relay identities.
struct NativeSSHControlMasterKey: Hashable, Sendable {
    let controlPath: String

    init?(
        configuration: WorkspaceRemoteConfiguration,
        sharingOptions: SSHConnectionSharingOptions
    ) {
        guard configuration.transport == .ssh,
              let controlPath = sharingOptions.cmuxOwnedControlPath(in: configuration.sshOptions),
              !controlPath.contains("%") else {
            return nil
        }
        // New native-SSH configurations resolve cmux's `%C` template through
        // `ssh -G` before reaching the app. Never claim lifecycle ownership of
        // an unresolved legacy template: aliases can expand to the same socket,
        // and treating their raw destination strings as distinct could close a
        // master that another workspace still uses. ControlPersist retires such
        // legacy masters after their bounded idle window.
        self.controlPath = controlPath
    }
}
