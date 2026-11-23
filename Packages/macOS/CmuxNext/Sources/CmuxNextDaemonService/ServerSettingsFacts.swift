import Foundation
public import Observation

/// What Settings > Server knows beside the handshakes: this Mac's control socket and Tailscale
/// address. Observed, so the page's host-lists watch sends them again when they change. The App's
/// server update presenter owns it (moved here with the ServerUpdates presenter seam).
@MainActor
@Observable
public final class ServerSettingsFacts {
    /// The local cmux-tui control socket, nil until the app connected.
    public var socketPath: String?
    /// This Mac's `100.x.y.z:port` when it serves over Tailscale, else nil.
    public var tailnetAddress: String?

    public init() {}
}
