public import Foundation

/// Daemon-signal-driven health of a remote workspace's cmuxd-remote daemon,
/// exposed through `workspace.remote.status` for the sidebar/inspector.
///
/// Every input is a real daemon signal — the hello handshake result
/// (``WorkspaceRemoteDaemonStatus``), daemon heartbeats, and live PTY
/// bridge counts — never bare TCP-reachability inference (the #7828 class
/// of bug this replaces).
public struct WorkspaceRemoteDaemonHealth: Equatable, Sendable {
    /// Health classification. Raw values are wire strings; do not rename.
    public enum State: String, Equatable, Sendable {
        /// Daemon answered its hello and the transport is connected.
        case running
        /// Daemon is bootstrapping, errored, or the transport is between
        /// reconnect attempts — signals disagree or are incomplete.
        case degraded
        /// Daemon answered but reports an older version than this client
        /// installs; `cmux vps upgrade` (or reconnect) will converge it.
        case needsUpgrade = "needs-upgrade"
        /// Automatic reconnect gave up; the host is not answering.
        case unreachable
        /// No daemon session exists (workspace disconnected or local).
        case unknown
    }

    /// Overall state.
    public var state: State
    /// Version the daemon reported in its hello, if any.
    public var daemonVersion: String?
    /// Daemon version this client ships/installs, if known.
    public var clientVersion: String?
    /// True when a version drift between daemon and client was detected.
    public var needsUpgrade: Bool
    /// Live PTY sessions this client has bridged to the daemon.
    public var ptySessionCount: Int
    /// Timestamp of the last daemon heartbeat, if any.
    public var lastSeenAt: Date?

    /// Creates a health snapshot (primarily for tests; production uses
    /// ``evaluate(connectionState:daemon:clientDaemonVersion:ptySessionCount:lastSeenAt:)``).
    public init(
        state: State,
        daemonVersion: String? = nil,
        clientVersion: String? = nil,
        needsUpgrade: Bool = false,
        ptySessionCount: Int = 0,
        lastSeenAt: Date? = nil
    ) {
        self.state = state
        self.daemonVersion = daemonVersion
        self.clientVersion = clientVersion
        self.needsUpgrade = needsUpgrade
        self.ptySessionCount = ptySessionCount
        self.lastSeenAt = lastSeenAt
    }

    /// Classifies daemon health from the signals the workspace already
    /// tracks.
    ///
    /// - Parameters:
    ///   - connectionState: Transport lifecycle state.
    ///   - daemon: Hello-handshake-driven daemon status.
    ///   - clientDaemonVersion: Version this client installs, or `nil`.
    ///   - ptySessionCount: Live PTY sessions bridged by this client.
    ///   - lastSeenAt: Last daemon heartbeat timestamp.
    /// - Returns: The classified health.
    public static func evaluate(
        connectionState: WorkspaceRemoteConnectionState,
        daemon: WorkspaceRemoteDaemonStatus,
        clientDaemonVersion: String?,
        ptySessionCount: Int,
        lastSeenAt: Date?
    ) -> WorkspaceRemoteDaemonHealth {
        let daemonVersion = daemon.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = clientDaemonVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let drift = versionDrift(daemonVersion: daemonVersion, clientVersion: clientVersion)

        let state: State
        switch (connectionState, daemon.state) {
        case (.suspended, _):
            state = .unreachable
        case (.connected, .ready):
            state = drift ? .needsUpgrade : .running
        case (.connected, _), (.connecting, _), (.reconnecting, _):
            state = .degraded
        case (.error, _):
            state = daemon.state == .error ? .degraded : .unreachable
        case (.disconnected, _):
            state = .unknown
        }

        return WorkspaceRemoteDaemonHealth(
            state: state,
            daemonVersion: daemonVersion?.isEmpty == false ? daemonVersion : nil,
            clientVersion: clientVersion?.isEmpty == false ? clientVersion : nil,
            needsUpgrade: drift,
            ptySessionCount: ptySessionCount,
            lastSeenAt: lastSeenAt
        )
    }

    /// True when both versions are known, releases (not dev builds), and
    /// different. Dev fingerprint versions never count as drift.
    public static func versionDrift(daemonVersion: String?, clientVersion: String?) -> Bool {
        guard let daemonVersion, let clientVersion,
              !daemonVersion.isEmpty, !clientVersion.isEmpty else {
            return false
        }
        guard !daemonVersion.contains("dev"), !clientVersion.contains("dev") else {
            return false
        }
        return daemonVersion != clientVersion
    }

    /// JSON-object payload for socket/CLI status responses.
    ///
    /// Wire shape: keys and `NSNull` placeholders are protocol output, do
    /// not rename or drop.
    public func payload(now: Date = Date()) -> [String: Any] {
        [
            "state": state.rawValue,
            "daemon_version": daemonVersion ?? NSNull(),
            "client_version": clientVersion ?? NSNull(),
            "needs_upgrade": needsUpgrade,
            "pty_sessions": ptySessionCount,
            "last_seen_age_seconds": lastSeenAt.map { max(0, now.timeIntervalSince($0)) } ?? NSNull(),
        ]
    }
}
