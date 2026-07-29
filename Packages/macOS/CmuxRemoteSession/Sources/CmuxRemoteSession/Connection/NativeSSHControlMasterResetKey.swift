internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Identifies the effective cmux-owned master that may be reset after an
/// OpenSSH-confirmed reverse-forward bind conflict.
///
/// Resolved socket paths are globally stable. An unresolved `%` template also
/// includes the configured endpoint so independent hosts do not share reset
/// state before OpenSSH expands the template.
struct NativeSSHControlMasterResetKey: Hashable, Sendable {
    let controlPath: String
    let destination: String?
    let port: Int?

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
            guard !destination.isEmpty else { return nil }
            self.destination = destination
            self.port = configuration.port
        } else {
            self.destination = nil
            self.port = nil
        }
    }
}
