import CmuxCloud
import Foundation

/// Why a Cloud terminal attachment stopped for good.
///
/// Every stop ends in a visible state: either the local pane is going away,
/// or the pane keeps a card that says what happened. A stop never leaves a
/// silent frozen frame that drops input.
enum CloudTuiManualMirrorStopReason: Equatable, Sendable {
    /// The local pane closed or is being replaced; nothing remains to present.
    case paneClosed
    /// The control plane answered that the user can no longer reach the
    /// machine (404 `vm_not_found`, 403, `vm_owner_mismatch`), or the machine
    /// left the user's machine list.
    case accessLost
    /// The account signed out; Cloud access ends for every team.
    case signedOut
    /// This Mac's Cloud sign-in was revoked (`403 vm_access_revoked`) while
    /// the app still holds the older session; only a new sign-in restores it.
    case signInRevoked
    /// Cloud Machines were disabled or suspended while the pane stayed open.
    case cloudUnavailable

    /// The stop a permanent access loss ends attachments with.
    init(accessLoss: CloudMachineAccessLoss) {
        self = accessLoss.isMachineScoped ? .accessLost : .signInRevoked
    }

    /// The card a pane keeps after the stop; nil when the pane is closing.
    var endedPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        switch self {
        case .paneClosed:
            return nil
        case .accessLost:
            return .init(
                title: String(localized: "cloud.overlay.accessLost.title", defaultValue: "Cloud machine unavailable"),
                detail: String(
                    localized: "cloud.overlay.accessLost.detail",
                    defaultValue: "You no longer have access to this machine."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        case .signedOut:
            return .init(
                title: String(localized: "cloud.overlay.signedOut.title", defaultValue: "Cloud session ended"),
                detail: String(
                    localized: "cloud.overlay.signedOut.detail",
                    defaultValue: "Sign in to cmux to reconnect this terminal."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        case .signInRevoked:
            return .init(
                title: String(localized: "cloud.overlay.signInRevoked.title", defaultValue: "Sign in again to reconnect"),
                detail: String(
                    localized: "cloud.overlay.signInRevoked.detail",
                    defaultValue: "Cloud access for this Mac sign-in was revoked. Sign out of cmux, then sign in again to reconnect this machine."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        case .cloudUnavailable:
            return .init(
                title: String(localized: "cloud.overlay.error.title", defaultValue: "Cloud session unavailable"),
                detail: String(
                    localized: "cloud.feature.disabled",
                    defaultValue: "Cloud Machines are temporarily unavailable."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        }
    }
}
