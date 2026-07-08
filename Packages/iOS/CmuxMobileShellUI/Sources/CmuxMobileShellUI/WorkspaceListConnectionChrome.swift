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
    static func chrome(
        hasStore: Bool,
        connectionRequiresReauth: Bool,
        connectionRecoveryFailed: Bool,
        isRecoveringConnection: Bool,
        connectionStatus: MobileMacConnectionStatus
    ) -> WorkspaceListConnectionChrome {
        if hasStore && connectionRequiresReauth {
            return .recoveryBanner
        }
        if connectionStatus != .connected {
            return .macStatusRow
        }
        if hasStore && (connectionRecoveryFailed || isRecoveringConnection) {
            return .recoveryBanner
        }
        return .none
    }
}
