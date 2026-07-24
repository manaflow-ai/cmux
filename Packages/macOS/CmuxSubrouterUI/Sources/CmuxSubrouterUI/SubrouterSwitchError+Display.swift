internal import Foundation
public import CmuxSubrouter

extension SubrouterSwitchError {
    /// A localized user-facing message for switch failures.
    public var displayMessage: String {
        switch self {
        case .integrationDisabled:
            return String(
                localized: "subrouter.switchError.disabled",
                defaultValue: "The subrouter integration is disabled in Settings."
            )
        case .switchUnsupported(let provider):
            let name = provider.displayName
            return String(
                localized: "subrouter.switchError.unsupported",
                defaultValue: "Switching \(name) accounts is not supported yet."
            )
        case .commandNotFound:
            return String(
                localized: "subrouter.switchError.notInstalled",
                defaultValue: "The sr CLI was not found. Install subrouter, or set its path in Settings."
            )
        case .commandFailed(let description):
            return String(
                localized: "subrouter.switchError.failed",
                defaultValue: "Switch failed: \(description)"
            )
        case .commandTimedOut:
            return String(
                localized: "subrouter.switchError.timedOut",
                defaultValue: "The sr CLI timed out."
            )
        case .switchAlreadyInFlight:
            return String(
                localized: "subrouter.switchError.inFlight",
                defaultValue: "Another account switch is already in progress."
            )
        case .remoteServerManagesSelection(let serverName):
            return String(
                localized: "subrouter.switchError.remoteServer",
                defaultValue: "Server \(serverName) assigns accounts per session automatically; there is no global switch."
            )
        }
    }
}
