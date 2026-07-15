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

    /// Inherited repository-local Git variables that would override the
    /// working directory passed to every hosted command; Git documents that
    /// these must be cleared when targeting another repository. The list is
    /// `git rev-parse --local-env-vars` plus `GIT_NAMESPACE`.
    static let repositoryLocalGitVariables = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_DIR",
        "GIT_GRAFT_FILE",
        "GIT_IMPLICIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_INTERNAL_SUPER_PREFIX",
        "GIT_NAMESPACE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_OBJECT_DIRECTORY",
        "GIT_PREFIX",
        "GIT_REPLACE_REF_BASE",
        "GIT_SHALLOW_FILE",
        "GIT_WORK_TREE",
    ]

    /// Runs a command locally, adding environment values without invoking a shell.
    ///
    /// Repository-local Git variables inherited from the calling process are
    /// always unset first so `directory` alone selects the repository; values
    /// passed in `environment` still win because `/usr/bin/env` applies
    /// assignments after removals.
    ///
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
        let removals = Self.repositoryLocalGitVariables.flatMap { ["-u", $0] }
        let assignments = effectiveEnvironment.keys.sorted().map { key in
            "\(key)=\(effectiveEnvironment[key] ?? "")"
        }
        return await commandRunner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: removals + assignments + [executable] + arguments,
            timeout: timeout
        )
    }
}
