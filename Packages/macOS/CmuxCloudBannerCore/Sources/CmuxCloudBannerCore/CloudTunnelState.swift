/// The app-managed tunnel lifecycle used by Cloud UI projections.
public enum CloudTunnelState: Sendable, Equatable {
    /// Down, and nothing is asking for it.
    case off
    /// Enrolling, saving the VPN configuration, or waiting for the link.
    case starting
    /// Waiting for the user to allow the system extension.
    case awaitingApproval
    /// The WireGuard link is connected.
    case up
    /// The link is being stopped.
    case stopping
    /// The last start attempt failed with a user-presentable message.
    case failed(String)

    /// The stable token used by socket payloads and `cmux vpn status`.
    public var wireName: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .awaitingApproval: return "awaiting-approval"
        case .up: return "up"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }

    /// Whether a start or stop operation is still settling.
    public var isSettling: Bool {
        switch self {
        case .starting, .awaitingApproval, .stopping: return true
        case .off, .up, .failed: return false
        }
    }

    /// The failure message, when this state represents a failed start.
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
