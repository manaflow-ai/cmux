/// The launch-command fields the session autosave fingerprint folds into its
/// hash, flattened off the app-target `AgentLaunchCommandSnapshot`.
///
/// Carries only the values the legacy
/// `TabManager.hashAgentLaunchCommand(_:into:)` combined, in declaration order,
/// so ``SessionFingerprintService`` reproduces the legacy hash byte-identically.
/// The app-side ``SessionFingerprintHosting`` witness maps the live snapshot
/// into this value; the package never imports the app type.
public struct SessionFingerprintAgentLaunchCommandSnapshot: Sendable, Equatable {
    /// Legacy `AgentLaunchCommandSnapshot.launcher`.
    public let launcher: String?
    /// Legacy `AgentLaunchCommandSnapshot.executablePath`.
    public let executablePath: String?
    /// Legacy `AgentLaunchCommandSnapshot.arguments`.
    public let arguments: [String]
    /// Legacy `AgentLaunchCommandSnapshot.workingDirectory`.
    public let workingDirectory: String?
    /// Legacy `AgentLaunchCommandSnapshot.environment`, hashed sorted by key.
    public let environment: [String: String]?
    /// Legacy `AgentLaunchCommandSnapshot.capturedAt`.
    public let capturedAt: Double?
    /// Legacy `AgentLaunchCommandSnapshot.source`.
    public let source: String?

    /// Creates a flattened launch-command fingerprint input.
    public init(
        launcher: String?,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        capturedAt: Double?,
        source: String?
    ) {
        self.launcher = launcher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.capturedAt = capturedAt
        self.source = source
    }
}
