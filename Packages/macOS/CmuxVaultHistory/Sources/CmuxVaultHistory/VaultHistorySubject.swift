public import Foundation

/// Stable and contextual identity for the subject of a History event.
public struct VaultHistorySubject: Hashable, Codable, Sendable {
    /// Runtime identity of the workspace associated with the event.
    public let workspaceId: UUID?
    /// Runtime identity of the window associated with the event.
    public let windowId: UUID?
    /// Native agent-session identifier for a session event.
    public let sessionId: String?
    /// Locale-independent agent identifier for a session event.
    public let agent: String?
    /// Working directory associated with the subject, when known.
    public let directory: String?

    /// Creates a subject from the identities known at event time.
    ///
    /// - Parameters:
    ///   - workspaceId: Runtime workspace identity, if the event belongs to a workspace.
    ///   - windowId: Runtime window identity, if the event belongs to a window.
    ///   - sessionId: Native agent-session identity for a derived session event.
    ///   - agent: Locale-independent agent identifier for a derived session event.
    ///   - directory: Working directory associated with the event, when known.
    public init(
        workspaceId: UUID? = nil,
        windowId: UUID? = nil,
        sessionId: String? = nil,
        agent: String? = nil,
        directory: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.windowId = windowId
        self.sessionId = sessionId
        self.agent = agent
        self.directory = directory
    }
}
