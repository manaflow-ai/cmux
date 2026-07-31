/// A structured launch capture transported by the surface-resume socket API.
public struct ControlAgentLaunchCommand: Sendable, Equatable {
    public let launcher: String?
    public let executablePath: String?
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?
    public let capturedAt: Double?
    public let source: String?

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

/// Structured data consumed by `cmux restore`.
///
/// `legacyCommand` is populated only for command-only records written by older
/// builds. New records keep argv and environment structured through process
/// replacement.
public struct ControlSurfaceRestoreRecord: Sendable, Equatable {
    public let modeRawValue: String
    public let kind: String
    public let checkpointID: String?
    public let source: String?
    public let workingDirectory: String?
    public let environment: [String: String]
    public let launchCommand: ControlAgentLaunchCommand?
    public let preparedArguments: [String]?
    public let permissionMode: String?
    public let legacyCommand: String?

    public init(
        modeRawValue: String,
        kind: String,
        checkpointID: String?,
        source: String?,
        workingDirectory: String?,
        environment: [String: String],
        launchCommand: ControlAgentLaunchCommand?,
        preparedArguments: [String]?,
        permissionMode: String?,
        legacyCommand: String?
    ) {
        self.modeRawValue = modeRawValue
        self.kind = kind
        self.checkpointID = checkpointID
        self.source = source
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.launchCommand = launchCommand
        self.preparedArguments = preparedArguments
        self.permissionMode = permissionMode
        self.legacyCommand = legacyCommand
    }
}
