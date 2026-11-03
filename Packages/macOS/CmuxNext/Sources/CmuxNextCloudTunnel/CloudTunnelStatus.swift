public import Foundation

/// Where the opt-in Cloud Tunnel stands, as Settings, `cmux cloud tunnel status` and MCP show it.
public enum CloudTunnelStatus: Sendable, Equatable {
    /// The setting is off. Nothing on the Mac routes to the Cloud network.
    case off
    /// This build cannot run the tunnel (no bundled extension, or not signed for one); the
    /// associated text says which.
    case unavailable(String)
    /// macOS waits for the user to allow the extension in System Settings.
    case awaitingApproval
    /// The extension is being installed, the peer enrolled or the tunnel started.
    case connecting
    /// The tunnel is up since the given date.
    case connected(since: Date?)
    /// The tunnel is being stopped.
    case disconnecting
    /// The last start failed; the associated text is the reason shown to the user.
    case failed(String)

    /// The stable word the CLI and MCP print (`off`, `unavailable`, `awaiting-approval`,
    /// `connecting`, `connected`, `disconnecting`, `failed`).
    public var name: String {
        switch self {
        case .off: "off"
        case .unavailable: "unavailable"
        case .awaitingApproval: "awaiting-approval"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        case .failed: "failed"
        }
    }

    /// The reason for ``unavailable(_:)`` or ``failed(_:)``, else `nil`.
    public var reason: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        default: nil
        }
    }
}
