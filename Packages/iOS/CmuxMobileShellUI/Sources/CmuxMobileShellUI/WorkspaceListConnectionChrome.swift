import CmuxMobileShellModel

/// Which single connection-chrome section the workspace list renders above the
/// workspace rows. The recovery banner and per-Mac status row overlap for real
/// connection drops, so exactly one surface wins.
///
/// Reauth renders the banner first because Sign Out is the only useful action.
/// Otherwise a non-connected Mac status renders the status row with host-scoped
/// actions. Store-level recovery only renders the banner while the aggregate
/// list status is still connected.
enum WorkspaceListConnectionChrome: Equatable {
    case none
    case recoveryBanner
    case macStatusRow

    /// Chooses exactly one connection surface when store recovery and Mac status
    /// updates overlap during the same real connection drop.
    init(
        hasStore: Bool,
        connectionRequiresReauth: Bool,
        connectionRecoveryFailed: Bool,
        isRecoveringConnection: Bool,
        connectionStatus: MobileMacConnectionStatus
    ) {
        if hasStore && connectionRequiresReauth {
            self = .recoveryBanner
        } else if connectionStatus != .connected {
            self = .macStatusRow
        } else if hasStore && (connectionRecoveryFailed || isRecoveringConnection) {
            self = .recoveryBanner
        } else {
            self = .none
        }
    }
}

/// Presentation of the stored-Mac reconnect episode in the workspace list.
/// The shell owns timing and failure state; this value only maps that state to
/// one spinner, message, and pair of recovery actions.
struct WorkspaceListStoredMacRecoveryPresentation: Equatable {
    let showsSpinner: Bool
    let title: String?
    let description: String?
    let showsRetry: Bool
    let showsAddDevice: Bool

    init(
        isRestoring: Bool,
        recoveryFailed: Bool,
        error: String?,
        guidance: String?
    ) {
        let showsFailure = !isRestoring && recoveryFailed
        showsSpinner = isRestoring
        title = showsFailure ? error : nil
        description = showsFailure ? guidance : nil
        showsRetry = isRestoring || showsFailure
        showsAddDevice = isRestoring || showsFailure
    }
}
