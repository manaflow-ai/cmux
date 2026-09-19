import Foundation

/// One local tmux session returned by the authoritative bundled CLI.
public struct LocalTmuxSessionSummary: Identifiable, Equatable, Sendable {
    /// Stable UI identity.
    ///
    /// Managed sessions use their logical UUID string. Unmanaged sessions use
    /// a tmux:<name> identity because the CLI intentionally has no logical id.
    public let id: String

    /// Registry-backed logical UUID for managed sessions.
    public let logicalID: UUID?

    /// tmux session name used for display and unmanaged attachment.
    public let name: String

    /// Last known working directory, when the CLI can report one.
    public let cwd: String?

    /// Number of currently attached tmux clients.
    public let clientCount: Int

    /// Whether the tmux session is currently live.
    public let isLive: Bool

    /// Whether cmux owns a registry record for this session.
    public let isManaged: Bool

    /// Creates one decoded local tmux session summary.
    ///
    /// - Parameters:
    ///   - id: Stable UI identity.
    ///   - logicalID: Registry-backed UUID for a managed session.
    ///   - name: tmux session name.
    ///   - cwd: Last known working directory.
    ///   - clientCount: Number of attached clients.
    ///   - isLive: Whether the tmux session is live.
    ///   - isManaged: Whether cmux owns a registry record for the session.
    public init(
        id: String,
        logicalID: UUID?,
        name: String,
        cwd: String?,
        clientCount: Int,
        isLive: Bool,
        isManaged: Bool
    ) {
        self.id = id
        self.logicalID = logicalID
        self.name = name
        self.cwd = cwd
        self.clientCount = clientCount
        self.isLive = isLive
        self.isManaged = isManaged
    }
}
