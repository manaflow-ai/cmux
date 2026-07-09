public import Foundation

/// The terminal package's pending-spawn request sent through the app-owned gate seam.
public struct TerminalSurfaceSpawnGateRequest: Sendable, Equatable {
    /// The requested command, or `nil` for the default shell.
    public let command: String?

    /// The requested working directory, if any.
    public let workingDirectory: String?

    /// Caller-requested environment additions, not the final managed environment.
    public let environmentAdditions: [String: String]

    /// The target surface identifier.
    public let surfaceId: UUID

    /// The owning workspace identifier.
    public let workspaceId: UUID

    /// The runtime creation source name.
    public let source: String

    /// Whether this evaluation is for a respawn of an existing runtime surface.
    public let isRespawn: Bool

    /// Creates a pending-spawn gate request.
    /// - Parameters:
    ///   - command: The requested command, or `nil` for the default shell.
    ///   - workingDirectory: The requested working directory, if any.
    ///   - environmentAdditions: Caller-requested environment additions.
    ///   - surfaceId: The target surface identifier.
    ///   - workspaceId: The owning workspace identifier.
    ///   - source: The runtime creation source name.
    ///   - isRespawn: Whether this evaluation is for a respawn.
    public init(
        command: String?,
        workingDirectory: String?,
        environmentAdditions: [String: String],
        surfaceId: UUID,
        workspaceId: UUID,
        source: String,
        isRespawn: Bool
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentAdditions = environmentAdditions
        self.surfaceId = surfaceId
        self.workspaceId = workspaceId
        self.source = source
        self.isRespawn = isRespawn
    }
}
