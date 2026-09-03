import Foundation

/// Failures the coordinator reports to callers that asked for the tunnel
/// explicitly (`cmux vpn up`, revoke). Descriptions are user-presentable and
/// carry no secrets or vendor detail beyond the VPN itself.
enum CloudTunnelError: Error, CustomStringConvertible, Equatable {
    /// This build cannot manage the tunnel; `reason` names the missing piece.
    case backendUnavailable(CloudTunnelFallbackReason)
    /// No signed-in Cloud VM client to enroll with.
    case notSignedIn
    /// macOS needs a restart before the extension can load.
    case rebootRequired
    /// macOS refused to load the extension because the app is not in the
    /// Applications folder.
    case appNotInApplicationsFolder
    /// The activation or start failed; `message` is already sanitized.
    case startFailed(String)
    /// A bounded wait ran out.
    case deadlineExceeded

    var description: String {
        switch self {
        case .backendUnavailable:
            return String(
                localized: "cloudTunnel.error.backendUnavailable",
                defaultValue: "This cmux build does not include the app-managed tunnel. Use `cmux vpn up` (wg-quick) instead."
            )
        case .notSignedIn:
            return String(
                localized: "cloudTunnel.error.notSignedIn",
                defaultValue: "Sign in to cmux Cloud first (`cmux auth login`), then retry."
            )
        case .rebootRequired:
            return String(
                localized: "cloudTunnel.error.rebootRequired",
                defaultValue: "macOS needs a restart to finish installing the cmux Cloud Tunnel extension."
            )
        case .appNotInApplicationsFolder:
            return String(
                localized: "cloudTunnel.error.appNotInApplicationsFolder",
                defaultValue: "macOS only loads the cmux Cloud Tunnel extension from the Applications folder. Move cmux.app to /Applications and retry."
            )
        case .startFailed(let message):
            let format = String(
                localized: "cloudTunnel.error.startFailed",
                defaultValue: "The tunnel could not start: %@"
            )
            return String(format: format, message)
        case .deadlineExceeded:
            return String(
                localized: "cloudTunnel.error.deadlineExceeded",
                defaultValue: "The tunnel did not come up in time."
            )
        }
    }
}
