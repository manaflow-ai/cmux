import Foundation

/// The overlay path a session rides (plans/cmux-next/remote-desktop.md 6.6).
public nonisolated enum RemotePath: String, Sendable, Hashable, CaseIterable, Codable {
    /// Peer to peer on the overlay (LAN or WAN).
    case direct
    /// Through the team's cloud region tunnel.
    case viaCloudRegion
    /// Through the Durable Object relay: the weakest path for video.
    case relayed
    /// An RFB (VNC) compatibility host: a TCP connection over the tailnet
    /// or LAN, outside the overlay (plans/cmux-next/remote-desktop.md 12).
    case compatibility
}

/// Live session status from the transport. The pane derives every visible
/// state from the latest value (`RemotePaneReducer`).
public nonisolated struct RemoteViewStatus: Sendable, Hashable {
    public var path: RemotePath
    /// Round-trip time of the path; nil until measured.
    public var rttMs: Int?
    /// Packet loss over the last feedback window, 0 to 100.
    public var lossPercent: Double
    public var state: RemoteSessionState
    /// Upstream media (microphone, camera, screen share) of the session.
    public var upstream: RemoteUpstreamStatus
    /// Why the session ended, in one short line from the transport (an rd carrier's close reason);
    /// nil while live and when the transport gives none. Read by tools, never shown in the pane.
    public var endReason: String?

    public init(
        path: RemotePath = .direct, rttMs: Int? = nil, lossPercent: Double = 0, state: RemoteSessionState,
        upstream: RemoteUpstreamStatus = RemoteUpstreamStatus(), endReason: String? = nil
    ) {
        self.path = path
        self.rttMs = rttMs
        self.lossPercent = lossPercent
        self.state = state
        self.upstream = upstream
        self.endReason = endReason
    }
}
