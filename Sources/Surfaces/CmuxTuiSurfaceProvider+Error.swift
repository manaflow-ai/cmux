import Foundation

/// Errors surfaced by a Cloud machine provider. Preview credentials never enter error text.
extension CmuxTuiSurfaceProvider {
    enum ProviderError: Error, LocalizedError {
        case notSignedIn
        case machineAsleep(String)
        case noWorkspaceOnMachine(String)
        case terminalNotCreated(String)
        case invalidSnapshot(String)
        case snapshotOnly(String)
        case stateUnavailable(String)
        case invalidPreviewURL
        /// No user-space WireGuard hub in this build (no bundled cmux-tui client).
        case hubUnavailable
        /// The private URL could not be rewritten onto the loopback forward.
        case localForwardURLUnavailable

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Cloud VM access requires sign-in. Run `cmux auth login`, then retry."
            case .machineAsleep(let id):
                return "\(id) is asleep; open it (`cmux vm shell \(id)`) to wake it before listing its terminals."
            case .noWorkspaceOnMachine(let id):
                return "\(id) has no cmux-tui workspace yet."
            case .terminalNotCreated(let detail):
                return "cmux-tui did not report the new terminal: \(detail)"
            case .invalidSnapshot(let id):
                return "cmux-tui returned an unversioned or malformed session snapshot for \(id)."
            case .snapshotOnly(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.snapshotOnly",
                        defaultValue: "%@ uses an older cmux-tui protocol. Refresh it to enable live sync and rename operations."
                    ),
                    id
                )
            case .stateUnavailable(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.renameTerminalUnavailable",
                        defaultValue: "The current state for %@ is unavailable. Refresh and retry before renaming."
                    ),
                    id
                )
            case .invalidPreviewURL:
                return String(
                    localized: "cloudTree.error.invalidPreviewURL",
                    defaultValue: "The Cloud service returned an unusable preview address. Refresh and retry."
                )
            case .hubUnavailable:
                return String(
                    localized: "cloudTree.error.hubUnavailable",
                    defaultValue: "This cmux build has no user-space WireGuard hub, so it cannot reach ports on Cloud machines."
                )
            case .localForwardURLUnavailable:
                return String(
                    localized: "cloudTree.error.localForwardURLUnavailable",
                    defaultValue: "cmux could not build a local address for this port forward."
                )
            }
        }
    }

}
