public import CmuxTerminalCore
public import Foundation

/// Complete app-owned inputs used to resolve one terminal process launch.
public struct TerminalSurfaceLaunchRequest: Sendable {
    /// The workspace that owns the terminal placement.
    public let workspaceID: UUID
    /// The app surface that owns the terminal presentation.
    public let surfaceID: UUID
    /// The stable terminal process identity across presentation replacement.
    public let terminalLifecycleID: UUID
    /// The optional Ghostty surface configuration template.
    public let configTemplate: CmuxSurfaceConfigTemplate?
    /// The requested initial working directory.
    public let workingDirectory: String?
    /// The zero-based session port offset from the configured base port.
    public let portOrdinal: Int
    /// The optional command entered through the app launch surface.
    public let initialCommand: String?
    /// The optional app-owned input sent after process launch.
    public let initialInput: String?
    /// The optional runtime-owned input sent before ``initialInput``.
    public let runtimeInitialInput: String?
    /// Environment values that replace the launch resolver's initial values.
    public let initialEnvironmentOverrides: [String: String]
    /// Environment values added after initial overrides are resolved.
    public let additionalEnvironment: [String: String]

    /// Creates one complete launch-resolution request.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace that owns the terminal placement.
    ///   - surfaceID: The app surface that owns the terminal presentation.
    ///   - terminalLifecycleID: The stable process identity. The default uses `surfaceID`.
    ///   - configTemplate: The optional Ghostty surface configuration template.
    ///   - workingDirectory: The requested initial working directory.
    ///   - portOrdinal: The zero-based offset from the configured session port base.
    ///   - initialCommand: The optional app launch command.
    ///   - initialInput: The optional app-owned input sent after launch.
    ///   - runtimeInitialInput: The optional runtime-owned input sent before `initialInput`.
    ///   - initialEnvironmentOverrides: Environment values that replace initial resolver values.
    ///   - additionalEnvironment: Environment values added after initial overrides.
    public init(
        workspaceID: UUID,
        surfaceID: UUID,
        terminalLifecycleID: UUID? = nil,
        configTemplate: CmuxSurfaceConfigTemplate?,
        workingDirectory: String?,
        portOrdinal: Int,
        initialCommand: String?,
        initialInput: String?,
        runtimeInitialInput: String? = nil,
        initialEnvironmentOverrides: [String: String],
        additionalEnvironment: [String: String]
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.terminalLifecycleID = terminalLifecycleID ?? surfaceID
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory
        self.portOrdinal = portOrdinal
        self.initialCommand = initialCommand
        self.initialInput = initialInput
        self.runtimeInitialInput = runtimeInitialInput
        self.initialEnvironmentOverrides = initialEnvironmentOverrides
        self.additionalEnvironment = additionalEnvironment
    }
}
