import CmuxMobileShellModel

/// The single connection presentation used by workspace detail.
///
/// Transient reconnects and settled offline states stay in the title chrome so
/// terminal content remains unobscured. Reauthentication is the only blocking
/// state because retrying cannot resolve it.
enum WorkspaceDetailConnectionChrome: Equatable {
    case none
    case recoveryBanner
    case statusLine(WorkspaceConnectionStatusLine)

    init(
        connectionRequiresReauth: Bool,
        connectionStatus: MobileMacConnectionStatus
    ) {
        if connectionRequiresReauth {
            self = .recoveryBanner
        } else {
            switch connectionStatus {
            case .connected:
                self = .none
            case .reconnecting:
                self = .statusLine(.reconnecting)
            case .unavailable:
                self = .statusLine(.notConnected)
            }
        }
    }

    var statusLine: WorkspaceConnectionStatusLine? {
        if case .statusLine(let line) = self { return line }
        return nil
    }

    var allowsManualReconnect: Bool {
        self == .statusLine(.notConnected)
    }
}
