import CmuxMobileShellModel

/// The subtle Mail-style status line rendered under the computers picker while
/// the connection is degraded. It informs without hiding content: workspace
/// rows and terminals stay visible and interactive underneath.
enum WorkspaceConnectionStatusLine: Equatable {
    /// A reconnect attempt is in flight (spinner + "Reconnecting…").
    case reconnecting
    /// No live connection and no attempt currently in flight ("Not Connected").
    case notConnected
}

/// Which single connection surface the workspace list presents.
///
/// Reauth renders the banner because Sign Out is the only useful action — the
/// Mac REJECTED the connection, so retrying cannot help and blocking chrome is
/// honest. Initial-connection restore renders the status row because there may
/// be no cached content to show and it carries the available recovery
/// actions. Every other degraded state is transient: content stays, and the
/// only chrome is the status line under the computers picker.
enum WorkspaceListConnectionChrome: Equatable {
    case none
    case recoveryBanner
    case macStatusRow
    case statusLine(WorkspaceConnectionStatusLine)

    init(
        hasStore: Bool,
        connectionRequiresReauth: Bool,
        connectionRecoveryFailed: Bool,
        isRecoveringConnection: Bool,
        connectionStatus: MobileMacConnectionStatus,
        tailscalePairingRequired: Bool = false,
        isInitialConnectionLoading: Bool = false,
        initialConnectionTimedOut: Bool = false
    ) {
        if hasStore && connectionRequiresReauth {
            self = .recoveryBanner
        } else if hasStore && tailscalePairingRequired {
            // Keep the workspace content visible while directing the user to
            // the scanner from the existing reconnect action. Tailscale setup
            // guidance belongs in the empty state, not in blocking chrome.
            self = .statusLine(.notConnected)
        } else if isInitialConnectionLoading || initialConnectionTimedOut {
            self = .macStatusRow
        } else if connectionStatus == .reconnecting || (hasStore && isRecoveringConnection) {
            self = .statusLine(.reconnecting)
        } else if connectionStatus == .unavailable || (hasStore && connectionRecoveryFailed) {
            self = .statusLine(.notConnected)
        } else {
            self = .none
        }
    }

    var statusLine: WorkspaceConnectionStatusLine? {
        if case .statusLine(let line) = self { return line }
        return nil
    }

    /// Whether the toolbar shows the Mac-update hint indicator. The hint is a
    /// healthy-connection affordance: while reauth, restore, or degraded chrome
    /// is on screen, an update suggestion would compete with recovery (and
    /// could describe a Mac we are no longer talking to).
    var showsMacUpdateHintIndicator: Bool { self == .none }
}
