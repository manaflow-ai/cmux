public import CmuxRemoteDaemon
internal import Foundation

// User-facing text for a failed cmuxd-remote bootstrap. Split from the
// coordinator's main file verbatim; tests pin this mapping against raw errors.
extension RemoteSessionCoordinator {
    /// Maps a bootstrap failure to the user-facing message: capability
    /// failures collapse to the app-localized missing-capability string,
    /// anything else surfaces its own description. Static because tests pin
    /// it directly against raw errors; the strings ride in explicitly
    /// (legacy read the app-localized strings in place).
    public static func userFacingRemoteDaemonBootstrapErrorMessage(
        _ error: any Error,
        strings: RemoteDaemonStrings
    ) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYSessionCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYSessionTokenCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) || lowered.contains(RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability) {
            return strings.missingRequiredCapabilitiesMessage([
                RemoteDaemonRPCClient.requiredPTYSessionCapability,
            ])
        }
        switch nsError.code {
        case 12, 20:
            // No daemon exists for the host's OS/architecture in this build
            // (or this build ships no daemon manifest at all). Retrying cannot
            // help, and nothing on the remote host needs repair.
            return String(
                localized: "remoteDaemon.bootstrap.noDaemonForPlatform",
                defaultValue: "This cmux build has no remote daemon for the remote host's platform"
            )
        case 24:
            return String(
                localized: "remoteDaemon.bootstrap.buildOutputEmpty",
                defaultValue: "The remote daemon files are missing or empty"
            )
        case 31:
            return String(
                localized: "remoteDaemon.upload.transferFailed",
                defaultValue: "Failed to upload remote daemon"
            )
        case 33:
            return String(
                localized: "remoteDaemon.upload.verifyFailed",
                defaultValue: "Remote daemon integrity verification failed"
            )
        case 32, 34:
            return String(
                localized: "remoteDaemon.upload.installFailed",
                defaultValue: "Failed to install remote daemon"
            )
        case 40, 42:
            let loweredMessage = message.lowercased()
            guard loweredMessage.contains("permission denied") else {
                return String(
                    localized: "remoteDaemon.bootstrap.helloFailed",
                    defaultValue: "Could not confirm that the remote daemon is ready"
                )
            }
            let detail = String(
                localized: "remoteDaemon.bootstrap.reason.permissionDenied",
                defaultValue: "Permission denied"
            )
            return String(
                format: String(
                    localized: "remoteDaemon.bootstrap.helloFailedWithDetail",
                    defaultValue: "Remote daemon launch failed: %@"
                ),
                detail
            )
        case 41:
            return String(
                localized: "remoteDaemon.bootstrap.helloFailed",
                defaultValue: "Could not confirm that the remote daemon is ready"
            )
        case 13:
            return String(
                localized: "remoteDaemon.bootstrap.probeFailed",
                defaultValue: "Could not inspect the remote daemon installation"
            )
        default:
            return String(
                localized: "remoteDaemon.bootstrap.failed",
                defaultValue: "Could not prepare the remote daemon"
            )
        }
    }
}
