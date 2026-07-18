/// Creation or replacement metadata for one daemon-owned terminal process.
public struct BackendTerminalLaunch: Equatable, Sendable {
    private static let maximumArguments = 1_024
    private static let maximumEnvironmentEntries = 1_024
    private static let maximumStringBytes = 64 * 1_024
    private static let maximumWorkingDirectoryBytes = 16 * 1_024
    private static let maximumEnvironmentNameBytes = 4 * 1_024
    private static let maximumInitialInputBytes = 1_024 * 1_024
    private static let maximumAggregateBytes = 2 * 1_024 * 1_024
    /// Initial working directory, or the daemon default when absent.
    public let workingDirectory: String?

    /// Shell command interpreted by the daemon's default shell, or `nil` for a login shell.
    public let command: String?

    /// Exact executable and argument vector, or `nil` for a login shell.
    public let arguments: [String]?

    /// Additional environment variables applied to the child process.
    public let environment: [String: String]

    /// Bytes written once after a successful process replacement or creation.
    public let initialInput: String?

    /// Whether a completed child leaves its terminal content available for inspection.
    public let waitAfterCommand: Bool

    /// Creates terminal launch metadata.
    ///
    /// `command` and `arguments` are mutually exclusive on the wire. Supplying both is rejected
    /// before the daemon changes state.
    ///
    /// - Parameters:
    ///   - workingDirectory: Initial working directory, or `nil` for the daemon default.
    ///   - command: Shell command, or `nil` for a login shell.
    ///   - arguments: Exact executable and argument vector, or `nil` for a login shell.
    ///   - environment: Additional child environment variables.
    ///   - initialInput: Text written exactly once after creation or replacement.
    ///   - waitAfterCommand: Whether completed child content remains attached.
    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
    }

    internal func validatedJSONParameters() throws -> [String: BackendJSONValue] {
        try validate()
        var parameters: [String: BackendJSONValue] = [:]
        if let workingDirectory { parameters["cwd"] = .string(workingDirectory) }
        if let command { parameters["command"] = .string(command) }
        if let arguments {
            parameters["argv"] = .array(arguments.map(BackendJSONValue.string))
        }
        if !environment.isEmpty {
            parameters["env"] = .array(
                environment.keys.sorted().map { name in
                    .object([
                        "name": .string(name),
                        "value": .string(environment[name] ?? ""),
                    ])
                }
            )
        }
        if let initialInput { parameters["initial_input"] = .string(initialInput) }
        if waitAfterCommand { parameters["wait_after_command"] = .bool(true) }
        return parameters
    }

    /// Rejects ambiguous, unbounded, or process-environment-invalid launch metadata locally.
    public func validate() throws {
        if command != nil, arguments != nil {
            throw BackendTerminalLaunchValidationError.mutuallyExclusiveCommandForms
        }
        if command == "" {
            throw BackendTerminalLaunchValidationError.emptyCommand
        }
        if arguments?.isEmpty == true {
            throw BackendTerminalLaunchValidationError.emptyArguments
        }
        if let arguments, arguments.count > Self.maximumArguments {
            throw BackendTerminalLaunchValidationError.tooManyArguments
        }
        if environment.count > Self.maximumEnvironmentEntries {
            throw BackendTerminalLaunchValidationError.tooManyEnvironmentEntries
        }
        try Self.validateText(
            workingDirectory,
            field: "workingDirectory",
            maximumBytes: Self.maximumWorkingDirectoryBytes
        )
        try Self.validateText(
            command,
            field: "command",
            maximumBytes: Self.maximumStringBytes
        )
        for argument in arguments ?? [] {
            try Self.validateText(
                argument,
                field: "argument",
                maximumBytes: Self.maximumStringBytes
            )
        }
        for (name, value) in environment {
            guard Self.isValidEnvironmentName(name) else {
                throw BackendTerminalLaunchValidationError.invalidEnvironmentName(name)
            }
            try Self.validateText(
                name,
                field: "environmentName",
                maximumBytes: Self.maximumEnvironmentNameBytes
            )
            try Self.validateText(
                value,
                field: "environmentValue",
                maximumBytes: Self.maximumStringBytes
            )
        }
        try Self.validateText(
            initialInput,
            field: "initialInput",
            maximumBytes: Self.maximumInitialInputBytes
        )
        let aggregateBytes = (workingDirectory?.utf8.count ?? 0)
            + (command?.utf8.count ?? 0)
            + (arguments ?? []).reduce(0) { $0 + $1.utf8.count }
            + environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + (initialInput?.utf8.count ?? 0)
        guard aggregateBytes <= Self.maximumAggregateBytes else {
            throw BackendTerminalLaunchValidationError.aggregatePayloadTooLarge
        }
    }

    private static func validateText(
        _ value: String?,
        field: String,
        maximumBytes: Int
    ) throws {
        guard let value else { return }
        if value.contains("\0") {
            throw BackendTerminalLaunchValidationError.containsNUL(field)
        }
        if value.utf8.count > maximumBytes {
            throw BackendTerminalLaunchValidationError.fieldTooLarge(field)
        }
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              (first == 95 || (65 ... 90).contains(first) || (97 ... 122).contains(first))
        else { return false }
        return name.utf8.dropFirst().allSatisfy { byte in
            byte == 95
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || (48 ... 57).contains(byte)
        }
    }
}

/// Deterministic local rejection reasons for terminal launch metadata.
public enum BackendTerminalLaunchValidationError: Error, Equatable, Sendable {
    case mutuallyExclusiveCommandForms
    case emptyCommand
    case emptyArguments
    case tooManyArguments
    case tooManyEnvironmentEntries
    case invalidEnvironmentName(String)
    case containsNUL(String)
    case fieldTooLarge(String)
    case aggregatePayloadTooLarge
}
