public import Foundation

/// Project, workspace, and agent-session identity used to group a capture.
public struct ArtifactCaptureContext: Equatable, Sendable {
    /// Root directory that owns `.cmux/artifacts`.
    public let projectRoot: URL
    /// Stable cmux workspace identity, when known.
    public let workspaceID: String?
    /// Human-readable workspace title, when known.
    public let workspaceTitle: String?
    /// Stable agent session identity, when known.
    public let sessionID: String?
    /// Agent family such as `codex` or `claude`, when known.
    public let agentName: String?

    /// Creates capture grouping context.
    ///
    /// - Parameters:
    ///   - projectRoot: Root directory that owns `.cmux/artifacts`.
    ///   - workspaceID: Stable cmux workspace identity, when known.
    ///   - workspaceTitle: Human-readable workspace title, when known.
    ///   - sessionID: Stable agent session identity, when known.
    ///   - agentName: Agent family, when known.
    public init(
        projectRoot: URL,
        workspaceID: String? = nil,
        workspaceTitle: String? = nil,
        sessionID: String? = nil,
        agentName: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.sessionID = sessionID
        self.agentName = agentName
    }
}
