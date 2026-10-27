import Foundation
import Observation

/// What Settings > Server knows beside the handshakes: this Mac's control socket and Tailscale
/// address. Observed, so the page's host-lists watch sends them again when they change.
@MainActor
@Observable
final class ServerSettingsFacts {
    /// The local cmux-tui control socket, nil until the app connected.
    var socketPath: String?
    /// This Mac's `100.x.y.z:port` when it serves over Tailscale, else nil.
    var tailnetAddress: String?
}
