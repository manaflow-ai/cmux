import Foundation

/// One server's row in Settings > Server: status, version line, an optional "Restart Recommended"
/// part, and where it can be reached. Every text is already localized.
public nonisolated struct ServerSettingsRow: Sendable, Equatable, Identifiable {
    /// The "Restart Recommended" part of a row: this server lacks capabilities the app can use.
    public struct Restart: Sendable, Equatable {
        /// Which server the button restarts.
        public var kind: ServerKind
        /// Where it runs.
        public var host: ServerHost
        /// "Restart Recommended".
        public var title: String
        /// What a restart turns on, or that the server is an older build.
        public var help: String
        /// "Restart cmux-tui…": opens the same confirm as the toast; nothing restarts without it.
        public var buttonTitle: String
    }

    /// Which server.
    public var kind: ServerKind
    /// Where it runs.
    public var host: ServerHost
    /// "cmux-tui", or "cmux-tui on cmux-mini".
    public var name: String
    /// True while the server answered its handshake. A server that stopped answering is not listed
    /// until it answers again, so a listed row is running.
    public var isRunning: Bool
    /// "Running".
    public var statusText: String
    /// "Version 0.67.0 · Build abc1234 · Protocol 12" (the parts the server reported).
    public var versionLine: String
    /// The restart part, nil when a restart would gain nothing.
    public var restart: Restart?
    /// The local control socket, for the local server only.
    public var socketPath: String?
    /// The Tailscale address other devices pair with, for the local server only.
    public var tailnetAddress: String?

    /// One row per server and host.
    public var id: String { "\(kind.rawValue)|\(host.key)" }
}
