public import Foundation

/// One valid process-launch form.
///
/// Construction is failable so callers cannot express both forms or an empty
/// argument vector.
public struct TerminalSurfaceLaunchForm: Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case command(String)
        case arguments([String])
    }

    private let storage: Storage

    public init?(command: String) {
        guard !command.isEmpty else { return nil }
        storage = .command(command)
    }

    public init?(arguments: [String]) {
        guard !arguments.isEmpty else { return nil }
        storage = .arguments(arguments)
    }

    /// Creates an argument-vector form whose non-empty shape is explicit.
    public static func arguments(
        first: String,
        remaining: [String] = []
    ) -> TerminalSurfaceLaunchForm {
        TerminalSurfaceLaunchForm(storage: .arguments([first] + remaining))
    }

    public init?(command: String?, arguments: [String]?) {
        switch (command, arguments) {
        case (.some(let command), nil):
            self.init(command: command)
        case (nil, .some(let arguments)):
            self.init(arguments: arguments)
        default:
            return nil
        }
    }

    public var command: String? {
        guard case .command(let command) = storage else { return nil }
        return command
    }

    public var arguments: [String]? {
        guard case .arguments(let arguments) = storage else { return nil }
        return arguments
    }

    static let fallbackLoginShell = TerminalSurfaceLaunchForm(
        storage: .arguments(["/bin/zsh", "-l"])
    )

    private init(storage: Storage) {
        self.storage = storage
    }
}

/// Fully resolved process launch shared by embedded Ghostty and the persistent backend.
public struct TerminalSurfaceResolvedLaunch: Equatable, Sendable {
    public let workingDirectory: String?
    public let launchForm: TerminalSurfaceLaunchForm
    public var command: String? { launchForm.command }
    public var arguments: [String]? { launchForm.arguments }
    public let environment: [String: String]
    public let initialInput: String?
    public let waitAfterCommand: Bool

    public init(
        workingDirectory: String?,
        launchForm: TerminalSurfaceLaunchForm,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool
    ) {
        self.workingDirectory = workingDirectory
        self.launchForm = launchForm
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
    }

    /// Compatibility initializer for clients that still hold optional launch fields.
    public init?(
        workingDirectory: String?,
        command: String?,
        arguments: [String]?,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool
    ) {
        guard let launchForm = TerminalSurfaceLaunchForm(
            command: command,
            arguments: arguments
        ) else { return nil }
        self.init(
            workingDirectory: workingDirectory,
            launchForm: launchForm,
            environment: environment,
            initialInput: initialInput,
            waitAfterCommand: waitAfterCommand
        )
    }
}
