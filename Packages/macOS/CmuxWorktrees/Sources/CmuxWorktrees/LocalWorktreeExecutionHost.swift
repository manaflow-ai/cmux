public import CmuxFoundation
public import Foundation

/// Runs worktree operations on the local machine through an injected command runner.
public struct LocalWorktreeExecutionHost: WorktreeExecutionHost, Sendable {
    /// The stable identity of the local host.
    public let id: WorktreeHostID

    /// The local user's absolute home-directory path.
    public let homeDirectory: String

    private let commandRunner: any CommandRunning
    private let additionalEnvironment: [String: String]

    /// Creates a local execution host.
    /// - Parameters:
    ///   - id: The stable local host identifier.
    ///   - homeDirectory: The home directory used for default worktree paths.
    ///   - commandRunner: The injected subprocess runner.
    ///   - additionalEnvironment: Environment values added to every hosted command.
    public init(
        id: WorktreeHostID = .local,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        commandRunner: any CommandRunning = CommandRunner(),
        additionalEnvironment: [String: String] = [:]
    ) {
        self.id = id
        self.homeDirectory = homeDirectory
        self.commandRunner = commandRunner
        self.additionalEnvironment = additionalEnvironment
    }

    /// Returns `true` because an initialized local runner is routable.
    /// - Returns: Always `true`; launch failures are still reported by ``run(directory:executable:arguments:environment:timeout:)``.
    public func isAvailable() async -> Bool {
        true
    }

    /// Runs a command locally, adding environment values without invoking a shell.
    /// - Parameters:
    ///   - directory: The local working directory.
    ///   - executable: The executable name or absolute path.
    ///   - arguments: Arguments passed directly to the executable.
    ///   - environment: Environment values added through `/usr/bin/env`.
    ///   - timeout: A bounded deadline in seconds, or `nil`.
    /// - Returns: The captured command result.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let effectiveEnvironment = additionalEnvironment.merging(environment) { _, operationValue in
            operationValue
        }
        guard !effectiveEnvironment.isEmpty else {
            return await commandRunner.run(
                directory: directory,
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }

        let assignments = effectiveEnvironment.keys.sorted().map { key in
            "\(key)=\(effectiveEnvironment[key] ?? "")"
        }
        return await commandRunner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: assignments + [executable] + arguments,
            timeout: timeout
        )
    }
}
