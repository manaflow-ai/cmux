/// A point-in-time health snapshot of the control-socket listener.
///
/// Combines listener-loop state with on-disk socket-path checks. ``isHealthy``
/// is true only when every signal is clean.
public struct SocketListenerHealth: Equatable, Sendable {
    /// Whether the listener believes it is running.
    public let isRunning: Bool
    /// Whether the accept loop (or accept source) is alive.
    public let acceptLoopAlive: Bool
    /// Whether the listener's current path equals the expected path.
    public let socketPathMatches: Bool
    /// Whether a socket inode exists at the expected path.
    public let socketPathExists: Bool
    /// Whether the socket inode at the path is the one this listener bound.
    public let socketPathOwnedByListener: Bool

    /// Creates a health snapshot from individual signals.
    public init(
        isRunning: Bool,
        acceptLoopAlive: Bool,
        socketPathMatches: Bool,
        socketPathExists: Bool,
        socketPathOwnedByListener: Bool
    ) {
        self.isRunning = isRunning
        self.acceptLoopAlive = acceptLoopAlive
        self.socketPathMatches = socketPathMatches
        self.socketPathExists = socketPathExists
        self.socketPathOwnedByListener = socketPathOwnedByListener
    }

    /// Stable identifiers for every failing signal, in fixed order.
    ///
    /// `socket_identity_mismatch` is reported only when the path matches and
    /// exists but is owned by another process, so it never duplicates the
    /// coarser path signals.
    public var failureSignals: [String] {
        var signals: [String] = []
        if !isRunning { signals.append("not_running") }
        if !acceptLoopAlive { signals.append("accept_loop_dead") }
        if !socketPathMatches { signals.append("socket_path_mismatch") }
        if !socketPathExists { signals.append("socket_missing") }
        if socketPathMatches && socketPathExists && !socketPathOwnedByListener {
            signals.append("socket_identity_mismatch")
        }
        return signals
    }

    /// True when no failure signal is present.
    public var isHealthy: Bool {
        failureSignals.isEmpty
    }
}
