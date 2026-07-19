public import Foundation

/// A bounded, content-free snapshot of one live coding-agent terminal.
///
/// The app updates these values when its deferred detector publishes a new
/// effective state. Socket and CLI consumers only copy this cached metadata;
/// they never trigger terminal capture or classification.
public struct CmuxAgentTerminalObservation: Codable, Sendable, Equatable {
    /// The cmux app process that owns the terminal.
    public let runtimeID: String
    /// The owning workspace UUID.
    public let workspaceID: UUID
    /// The stable cmux surface UUID.
    public let surfaceID: UUID
    /// The native terminal lifetime that produced this observation.
    public let surfaceGeneration: UInt64
    /// The terminal dirty-signal revision that was classified.
    public let revision: UInt64
    /// The detector catalog family identifier.
    public let familyID: String
    /// The canonical hook/session provider identifier used by `cmux agents`.
    public let sessionProviderID: String
    /// Whether complete lifecycle hooks take precedence over terminal evidence.
    public let lifecycleAuthoritative: Bool
    /// The observed terminal interaction state.
    public let state: CmuxAgentObservedState
    /// The foreground process identifier.
    public let pid: Int32
    /// Kernel process start-time seconds.
    public let processStartSeconds: Int64
    /// Kernel process start-time microseconds.
    public let processStartMicroseconds: Int64
    /// The terminal's requested working directory, when available.
    public let cwd: String?
    /// Wall-clock time when cmux published this cached observation.
    public let publishedAt: TimeInterval

    /// Creates one live terminal observation.
    public init(
        runtimeID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        surfaceGeneration: UInt64,
        revision: UInt64,
        familyID: String,
        sessionProviderID: String,
        lifecycleAuthoritative: Bool,
        state: CmuxAgentObservedState,
        pid: Int32,
        processStartSeconds: Int64,
        processStartMicroseconds: Int64,
        cwd: String?,
        publishedAt: TimeInterval
    ) {
        self.runtimeID = runtimeID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.revision = revision
        self.familyID = familyID
        self.sessionProviderID = sessionProviderID
        self.lifecycleAuthoritative = lifecycleAuthoritative
        self.state = state
        self.pid = pid
        self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds
        self.cwd = cwd
        self.publishedAt = publishedAt
    }

    enum CodingKeys: String, CodingKey {
        case runtimeID = "runtime_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case surfaceGeneration = "surface_generation"
        case revision
        case familyID = "family_id"
        case sessionProviderID = "session_provider_id"
        case lifecycleAuthoritative = "lifecycle_authoritative"
        case state
        case pid
        case processStartSeconds = "process_start_seconds"
        case processStartMicroseconds = "process_start_microseconds"
        case cwd
        case publishedAt = "published_at"
    }
}
