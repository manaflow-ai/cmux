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

    /// Creates a shell command launch form.
    ///
    /// - Parameter command: The nonempty command passed to Ghostty for shell evaluation.
    public init?(command: String) {
        guard !command.isEmpty else { return nil }
        storage = .command(command)
    }

    /// Creates a direct executable launch form.
    ///
    /// - Parameter arguments: The executable path followed by its literal arguments.
    public init?(arguments: [String]) {
        guard let executable = arguments.first, !executable.isEmpty else { return nil }
        storage = .arguments(arguments)
    }

    /// Creates a launch form from exactly one optional representation.
    ///
    /// - Parameters:
    ///   - command: A command for shell evaluation.
    ///   - arguments: An executable path followed by literal arguments.
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

    /// The shell command, or `nil` for a direct executable launch.
    public var command: String? {
        guard case .command(let command) = storage else { return nil }
        return command
    }

    /// The direct executable arguments, or `nil` for a shell command launch.
    public var arguments: [String]? {
        guard case .arguments(let arguments) = storage else { return nil }
        return arguments
    }

    /// Safe login-shell fallback used when no configured launch form is valid.
    public static let fallbackLoginShell = TerminalSurfaceLaunchForm(
        storage: .arguments(["/bin/zsh", "-l"])
    )

    private init(storage: Storage) {
        self.storage = storage
    }
}

/// Fully resolved process launch shared by embedded Ghostty and the persistent backend.
public struct TerminalSurfaceResolvedLaunch: Equatable, Sendable {
    /// The resolved initial working directory.
    public let workingDirectory: String?
    /// The single validated command or direct executable form.
    public let launchForm: TerminalSurfaceLaunchForm
    /// The shell command, or `nil` for a direct executable launch.
    public var command: String? { launchForm.command }
    /// The executable path and literal arguments, or `nil` for a shell command launch.
    public var arguments: [String]? { launchForm.arguments }
    /// The complete process environment.
    public let environment: [String: String]
    /// Input sent after the process starts.
    public let initialInput: String?
    /// Whether the terminal remains open after the command exits.
    public let waitAfterCommand: Bool

    /// Creates a resolved launch from one validated launch form.
    ///
    /// - Parameters:
    ///   - workingDirectory: The resolved initial working directory.
    ///   - launchForm: The validated shell command or direct executable form.
    ///   - environment: The complete process environment.
    ///   - initialInput: Input sent after the process starts.
    ///   - waitAfterCommand: Whether the terminal remains open after command exit.
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

    /// Creates a resolved launch for clients that still hold optional launch fields.
    ///
    /// Exactly one of `command` or `arguments` must be present and nonempty.
    ///
    /// - Parameters:
    ///   - workingDirectory: The resolved initial working directory.
    ///   - command: A command for shell evaluation.
    ///   - arguments: An executable path followed by literal arguments.
    ///   - environment: The complete process environment.
    ///   - initialInput: Input sent after the process starts.
    ///   - waitAfterCommand: Whether the terminal remains open after command exit.
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
