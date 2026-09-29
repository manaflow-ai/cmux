public import Foundation

/// Identifies one terminal owned by the cmux-tui daemon.
public struct TerminalID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Where the daemon listens. Resolution rules (bundled daemon, tagged
/// socket paths) belong to the daemon-client agent; this only carries the path.
public struct DaemonEndpoint: Hashable, Sendable {
    public let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }
}

/// Topology and lifecycle events from the daemon. Terminal output travels on
/// a separate per-terminal stream so a busy PTY cannot delay these.
public enum DaemonEvent: Sendable, Equatable {
    case connected
    case disconnected(reason: String)
}

/// Commands the frontend sends. Stores never mutate topology locally; they
/// send a command and apply the resulting event.
public enum DaemonCommand: Sendable, Equatable {
    case write(terminal: TerminalID, bytes: Data)
    case resize(terminal: TerminalID, columns: Int, rows: Int)
}

public enum DaemonError: Error, Sendable, Equatable {
    case notConnected
}

/// Seam between the app and the daemon transport, so models and previews can
/// run against a fake.
public protocol DaemonConnecting: Actor {
    /// Control events. A new stream is returned per call; reconnect means a
    /// new stream plus a snapshot resync.
    func events() -> AsyncStream<DaemonEvent>

    /// Output bytes for one terminal, in order, for `ghostty_surface_process_output`.
    func output(for terminal: TerminalID) -> AsyncStream<Data>

    func send(_ command: DaemonCommand) async throws
}
