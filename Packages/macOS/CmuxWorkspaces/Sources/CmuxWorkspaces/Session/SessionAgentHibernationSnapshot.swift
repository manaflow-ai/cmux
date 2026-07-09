public import Foundation

/// The persisted agent-hibernation timestamps inside a session snapshot.
///
/// A pure leaf value carrying when the agent `hibernatedAt` and its
/// `lastActivityAt`, both as `timeIntervalSince1970`. The on-disk wire format is
/// owned by the app's `SessionTerminalPanelSnapshot`; encoding stays
/// byte-identical to the legacy app-target definition.
public struct SessionAgentHibernationSnapshot: Codable, Sendable {
    /// When the agent was hibernated, as `timeIntervalSince1970`.
    public var hibernatedAt: TimeInterval
    /// The agent's last activity time, as `timeIntervalSince1970`.
    public var lastActivityAt: TimeInterval

    /// Creates a persisted agent-hibernation snapshot.
    public init(hibernatedAt: TimeInterval, lastActivityAt: TimeInterval) {
        self.hibernatedAt = hibernatedAt
        self.lastActivityAt = lastActivityAt
    }
}
