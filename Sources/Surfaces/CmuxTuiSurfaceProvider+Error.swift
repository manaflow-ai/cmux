import Foundation

/// Errors surfaced by a Cloud machine provider. Preview credentials never enter error text.
extension CmuxTuiSurfaceProvider {
    enum ProviderError: Error, LocalizedError {
        case notSignedIn
        case machineAsleep(String)
        case noWorkspaceOnMachine(String)
        /// The daemon could not prove whether a correlated creation committed.
        case terminalCreationOutcomeUnknown(String)
        /// The daemon predates the durable creation-resolution contract.
        case terminalCreationUnsupported(String)
        case remoteWorkspaceNotFound(String)
        case remotePlacementUnavailable(String)
        case remoteTabNotFound(String)
        /// The terminal's process already ended on the machine.
        case terminalExited(String)
        /// The daemon did not answer the resolver within the bounded retries.
        /// The terminal may still be running; this is never "not created".
        case terminalAttachTimedOut(terminalID: String, failure: CloudTuiSurfaceIDResolution.Failure)
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
            case .terminalCreationOutcomeUnknown:
                return String(
                    localized: "cloudTree.error.terminalCreationOutcomeUnknown",
                    defaultValue: "Cloud could not confirm whether the terminal was created. Refresh the machine before retrying."
                )
            case .terminalCreationUnsupported:
                return String(
                    localized: "cloudTree.error.terminalCreationUnsupported",
                    defaultValue: "This machine does not support safe Cloud terminal recovery. Update its cmux-tui daemon before retrying."
                )
            case .remoteWorkspaceNotFound(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.remoteWorkspaceNotFound",
                        defaultValue: "Remote workspace %@ is no longer available. Refresh and retry."
                    ),
                    id
                )
            case .remotePlacementUnavailable(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.remotePlacementUnavailable",
                        defaultValue: "Remote workspace %@ has no available terminal placement. Refresh and retry."
                    ),
                    id
                )
            case .remoteTabNotFound(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.remoteTabNotFound",
                        defaultValue: "Remote tab %@ is no longer available. Refresh and retry."
                    ),
                    id
                )
            case .terminalExited(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.terminalExited",
                        defaultValue: "%@ already exited on the machine."
                    ),
                    id
                )
            case let .terminalAttachTimedOut(terminalID, failure):
                return String(
                    format: String(
                        localized: "cloudTree.error.terminalAttachTimedOut",
                        defaultValue: "Could not attach %@ in time (%@). The terminal may still be running on the machine; try opening it again."
                    ),
                    terminalID,
                    failure.localizedDescription
                )
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
