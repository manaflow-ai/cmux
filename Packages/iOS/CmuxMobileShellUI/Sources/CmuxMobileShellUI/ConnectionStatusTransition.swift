import CmuxMobileShellModel

/// One display state for the connection-status capsule, derived from the
/// authoritative store signals. Recovery flags outrank the workspace status
/// because a same-client probe (`markMacConnectionReconnecting` /
/// `markMacConnectionHealthy`) can cycle while both the transport state and
/// the workspace's Mac status stay `.connected`.
enum ConnectionStatusDisplayState: Equatable {
    /// The capsule stays clear: the user is signed out, or reauth's durable
    /// banner owns the surface. Both are blocking conditions, not statuses.
    case suppressed
    /// Recovery failed: the durable banner owns Retry and the capsule clears,
    /// but recovering back to connected still deserves a success toast.
    case failed
    case reconnecting
    case unavailable
    case connected

    /// `workspaceStatus` is the per-Mac status the pill and legacy overlay
    /// already display. The foreground transport (`connectionState`) is
    /// deliberately NOT an input: it describes only the foreground RPC
    /// connection, and a selected workspace on a healthy secondary Mac would
    /// falsely read as disconnected (see `workspaceListConnectionStatus`).
    static func derive(
        isSignedIn: Bool,
        requiresReauth: Bool,
        recoveryFailed: Bool,
        isRecovering: Bool,
        workspaceStatus: MobileMacConnectionStatus
    ) -> Self {
        guard isSignedIn else {
            return .suppressed
        }
        if requiresReauth {
            return .suppressed
        }
        if recoveryFailed {
            return .failed
        }
        if isRecovering {
            return .reconnecting
        }
        switch workspaceStatus {
        case .unavailable:
            return .unavailable
        case .reconnecting:
            return .reconnecting
        case .connected:
            return .connected
        }
    }
}

/// What the capsule should reflect, scoped to the workspace whose status
/// produced it so cross-workspace selection changes never read as recovery.
struct ConnectionStatusSnapshot: Equatable {
    var workspaceID: MobileWorkspacePreview.ID?
    var display: ConnectionStatusDisplayState
}

/// The single presentation decision for a snapshot transition.
enum ConnectionStatusToastTransition: Equatable {
    case none
    case dismiss
    case unavailable
    case reconnecting
    case reconnected

    static func decide(
        from previous: ConnectionStatusSnapshot,
        to current: ConnectionStatusSnapshot
    ) -> Self {
        switch current.display {
        case .suppressed, .failed:
            // A durable banner (reauth, failed recovery) or the signed-out
            // screen takes over the surface.
            return .dismiss
        case .reconnecting:
            return .reconnecting
        case .unavailable:
            return .unavailable
        case .connected:
            guard previous.workspaceID == current.workspaceID else {
                // Selecting a healthy workspace is not a recovery, but a
                // lingering toast for the previous workspace would keep a
                // Reconnect action aimed at the wrong Mac.
                return .dismiss
            }
            switch previous.display {
            case .failed, .reconnecting, .unavailable:
                return .reconnected
            case .connected, .suppressed:
                return .none
            }
        }
    }
}
