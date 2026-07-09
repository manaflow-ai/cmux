public import Foundation

/// The pending local terminal spawn sent to a pre-spawn hook.
public struct SpawnHookRequest: Sendable, Encodable, Equatable {
    /// The requested command, or `nil` for the default login shell.
    public let command: String?

    /// The requested working directory, if any.
    public let workingDirectory: String?

    /// Caller-requested environment additions, not cmux's full managed environment.
    public let environmentAdditions: [String: String]

    /// The target terminal surface identifier.
    public let surfaceId: String

    /// The owning workspace identifier.
    public let workspaceId: String

    /// The runtime creation source name.
    public let source: String

    /// Whether this evaluation is for a respawn of an existing runtime surface.
    public let isRespawn: Bool

    /// The application name.
    public let app: String

    /// Creates a pre-spawn hook request.
    /// - Parameters:
    ///   - command: The requested command, or `nil` for the default shell.
    ///   - workingDirectory: The requested working directory, if any.
    ///   - environmentAdditions: Caller-requested environment additions.
    ///   - surfaceId: The target terminal surface identifier.
    ///   - workspaceId: The owning workspace identifier.
    ///   - source: The runtime creation source name.
    ///   - isRespawn: Whether this evaluation is for a respawn.
    ///   - app: The application name.
    public init(
        command: String?,
        workingDirectory: String?,
        environmentAdditions: [String: String],
        surfaceId: String,
        workspaceId: String,
        source: String,
        isRespawn: Bool,
        app: String = "cmux"
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentAdditions = environmentAdditions
        self.surfaceId = surfaceId
        self.workspaceId = workspaceId
        self.source = source
        self.isRespawn = isRespawn
        self.app = app
    }

    /// Encodes this request as the pre-spawn hook stdin envelope.
    /// - Returns: Stable sorted JSON bytes.
    public func envelopeJSON() throws -> Data {
        let envelope = SpawnHookRequestEnvelope(hook: "preSpawn", spawn: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
}

private struct SpawnHookRequestEnvelope: Encodable {
    let hook: String
    let spawn: SpawnHookRequest
}
