import Foundation

/// Captures the replaceable replicated metadata for one agent session.
public struct AgentSessionSnapshot: Codable, Hashable, Sendable {
    /// The session identifier, scoped by ``macDeviceID``.
    public let id: AgentSessionID
    /// The Mac that owns this session.
    public let macDeviceID: MacDeviceID
    /// The agent implementation kind.
    public let kind: AgentKind
    /// The current display phase.
    public let phase: SessionPhase
    /// The current detection tier.
    public let tier: DetectionTier
    /// The optional surface identifier that displays the session.
    public let surfaceID: String?
    /// The current working directory display value.
    public let cwd: String
    /// The session title display value.
    public let title: String
    /// The workspace name display value.
    public let workspaceName: String
    /// The entity version for this snapshot in the current epoch.
    public let version: EntityVersion
    /// An opaque recency hint used only for display ordering.
    public let lastActivityHint: Int

    /// Creates a session snapshot.
    /// - Parameters:
    ///   - id: The session identifier.
    ///   - macDeviceID: The owning Mac identifier.
    ///   - kind: The agent kind.
    ///   - phase: The display phase.
    ///   - tier: The detection tier.
    ///   - surfaceID: The optional surface identifier.
    ///   - cwd: The working directory display value.
    ///   - title: The session title.
    ///   - workspaceName: The workspace display value.
    ///   - version: The entity version in the current epoch.
    ///   - lastActivityHint: The opaque recency hint.
    public init(
        id: AgentSessionID,
        macDeviceID: MacDeviceID,
        kind: AgentKind,
        phase: SessionPhase,
        tier: DetectionTier,
        surfaceID: String?,
        cwd: String,
        title: String,
        workspaceName: String,
        version: EntityVersion,
        lastActivityHint: Int
    ) {
        self.id = id
        self.macDeviceID = macDeviceID
        self.kind = kind
        self.phase = phase
        self.tier = tier
        self.surfaceID = surfaceID
        self.cwd = cwd
        self.title = title
        self.workspaceName = workspaceName
        self.version = version
        self.lastActivityHint = lastActivityHint
    }
}
