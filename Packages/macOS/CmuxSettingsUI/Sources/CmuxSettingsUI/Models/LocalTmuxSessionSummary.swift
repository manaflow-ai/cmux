import Foundation

/// One local tmux session returned by the authoritative bundled CLI.
nonisolated public struct LocalTmuxSessionSummary: Identifiable, Equatable, Sendable {
    /// The complete attachment identity; display and action selectors derive from it.
    public enum Selector: Equatable, Sendable {
        /// A registry-owned session, including its display name.
        case managed(id: UUID, name: String)
        /// A session addressed by its tmux name.
        case unmanaged(name: String)
    }

    /// Authoritative selector for this session.
    public let selector: Selector

    /// Stable UI identity, derived from the attachment selector.
    public var id: String {
        switch selector {
        case .managed(let id, _): return id.uuidString
        case .unmanaged(let name): return "tmux:\(name)"
        }
    }

    /// Registry-backed logical UUID for managed sessions.
    public var logicalID: UUID? {
        if case .managed(let id, _) = selector { return id }
        return nil
    }

    /// tmux session name used for display and unmanaged attachment.
    public var name: String {
        switch selector {
        case .managed(_, let name), .unmanaged(let name): return name
        }
    }

    /// Last known working directory, when the CLI can report one.
    public let cwd: String?
    /// Number of currently attached tmux clients.
    public let clientCount: Int
    /// Whether the tmux session is currently live.
    public let isLive: Bool
    /// Whether cmux owns a registry record for this session.
    public var isManaged: Bool { logicalID != nil }

    /// Creates a summary whose UI identity and attachment selector cannot diverge.
    public init(
        selector: Selector,
        cwd: String?,
        clientCount: Int,
        isLive: Bool
    ) {
        self.selector = selector
        self.cwd = cwd
        self.clientCount = clientCount
        self.isLive = isLive
    }
}
