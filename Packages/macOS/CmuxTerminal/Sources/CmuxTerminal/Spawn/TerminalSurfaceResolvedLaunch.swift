public import Foundation

/// Fully resolved process launch shared by embedded Ghostty and the persistent backend.
public struct TerminalSurfaceResolvedLaunch: Equatable, Sendable {
    public let workingDirectory: String?
    public let command: String?
    public let arguments: [String]?
    public let environment: [String: String]
    public let initialInput: String?
    public let waitAfterCommand: Bool

    public init(
        workingDirectory: String?,
        command: String?,
        arguments: [String]?,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool
    ) {
        precondition(command == nil || arguments == nil)
        precondition(command != nil || arguments?.isEmpty == false)
        self.workingDirectory = workingDirectory
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
    }
}
