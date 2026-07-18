public import CmuxTerminalCore
public import Foundation

/// Complete app-owned inputs used to resolve one terminal process launch.
public struct TerminalSurfaceLaunchRequest: Sendable {
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let configTemplate: CmuxSurfaceConfigTemplate?
    public let workingDirectory: String?
    public let portOrdinal: Int
    public let initialCommand: String?
    public let initialInput: String?
    public let runtimeInitialInput: String?
    public let initialEnvironmentOverrides: [String: String]
    public let additionalEnvironment: [String: String]

    public init(
        workspaceID: UUID,
        surfaceID: UUID,
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
