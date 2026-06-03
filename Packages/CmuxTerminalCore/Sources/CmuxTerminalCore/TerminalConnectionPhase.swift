/// The lifecycle phase of a terminal workspace's connection to its host.
public enum TerminalConnectionPhase: String, Codable, CaseIterable, Sendable {
    /// The host is missing required configuration (e.g. SSH details) before it can connect.
    case needsConfiguration
    /// The workspace is configured but not yet attempting a connection.
    case idle
    /// A connection attempt is in progress.
    case connecting
    /// The workspace is connected and live.
    case connected
    /// The connection dropped and a reconnect attempt is in progress.
    case reconnecting
    /// The connection was disconnected and is not currently retrying.
    case disconnected
    /// A connection attempt failed.
    case failed
}
