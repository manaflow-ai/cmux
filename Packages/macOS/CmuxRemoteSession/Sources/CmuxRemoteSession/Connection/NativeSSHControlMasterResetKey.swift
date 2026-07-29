internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Identifies the effective cmux-owned master that may be reset after an
/// OpenSSH-confirmed reverse-forward bind conflict.
///
/// Resolved socket paths are globally stable. An unresolved `%` template is
/// intentionally scoped to one owner and its full explicit SSH identity:
/// without `ssh -G` expansion, coalescing separate owners could falsely claim
/// that an exit for one effective socket reset another.
struct NativeSSHControlMasterResetKey: Hashable, Sendable {
    let controlPath: String
    let destination: String?
    let port: Int?
    let identityFile: String?
    let effectiveOptions: [String]
    let ownerWorkspaceID: UUID?

    init?(
        configuration: WorkspaceRemoteConfiguration,
        sharingOptions: SSHConnectionSharingOptions
    ) {
        guard configuration.transport == .ssh else { return nil }
        let effectiveOptions = sharingOptions.mergingDefaults(
            into: configuration.sshOptions
        )
        guard let controlPath = sharingOptions.cmuxOwnedControlPath(
            in: effectiveOptions
        ) else {
            return nil
        }
        self.controlPath = controlPath
        if controlPath.contains("%") {
            let destination = configuration.destination
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty,
                  let ownerWorkspaceID = configuration.ownerWorkspaceID else {
                return nil
            }
            self.destination = destination
            self.port = configuration.port
            self.identityFile = configuration.identityFile?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.effectiveOptions = effectiveOptions
            self.ownerWorkspaceID = ownerWorkspaceID
        } else {
            self.destination = nil
            self.port = nil
            self.identityFile = nil
            self.effectiveOptions = []
            self.ownerWorkspaceID = nil
        }
    }
}
