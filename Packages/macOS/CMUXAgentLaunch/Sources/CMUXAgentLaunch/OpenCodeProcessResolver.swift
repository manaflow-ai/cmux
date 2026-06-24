public import Foundation

/// Resolves the executable path, launch argument vector, and working directory
/// for an observed OpenCode process from its argv/environment alone.
///
/// This is the pure argv/path-parsing half of OpenCode process detection. It
/// owns no app state and performs no database work; the SQLite-backed
/// fork-parent session lookup (`OpenCodeDatabaseSnapshot`) stays app-side and
/// only consumes the working directory this resolver derives.
///
/// The injected `FileManager` backs the `PATH` executable-existence probe so the
/// resolver is testable against a scoped filesystem.
public struct OpenCodeProcessResolver {
    private let fileManager: FileManager

    /// Creates a resolver.
    /// - Parameter fileManager: Filesystem used to probe `PATH` for an
    ///   executable when the argv does not carry an absolute path.
    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    /// Resolves the absolute (or best-effort) executable path for an observed
    /// OpenCode process, preferring an explicit argv executable, then a
    /// `PATH`-resolved name, then the process path, then a `PATH`-resolved
    /// `opencode`.
    public func executablePath(
        observed: VaultObservedAgentProcess,
        environment: [String: String]
    ) -> String {
        let argumentExecutable = observed.openCodeExecutableArgument
        if let argumentExecutable,
           argumentExecutable.contains("/") {
            return argumentExecutable
        }
        if let argumentExecutable,
           let resolved = executablePath(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           VaultObservedAgentProcess.argumentLooksLikeOpenCode(processPath) {
            return processPath
        }
        if let resolved = executablePath(named: "opencode", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "opencode"
    }

    /// Builds the sanitized launch argument vector (executable plus preserved
    /// arguments) for an observed OpenCode process, or `nil` when the arguments
    /// cannot be preserved.
    public func launchArguments(
        observed: VaultObservedAgentProcess,
        executablePath: String
    ) -> [String]? {
        let tail = launchTail(observed: observed)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: tail) else {
            return nil
        }
        return [executablePath] + preserved
    }

    /// Extracts the argument tail that follows the OpenCode executable token,
    /// accounting for node-runtime wrappers and leading-option-only invocations.
    public func launchTail(observed: VaultObservedAgentProcess) -> [String] {
        let arguments = observed.arguments
        guard !arguments.isEmpty else { return [] }
        if let executableIndex = observed.openCodeExecutableArgumentIndex {
            return Array(arguments.dropFirst(executableIndex + 1))
        }
        let processIdentityLooksLikeOpenCode = observed.executableBasenames.contains { basename in
            VaultObservedAgentProcess.argumentLooksLikeOpenCode(basename)
        }
        guard processIdentityLooksLikeOpenCode else { return [] }
        if arguments[0].hasPrefix("-") {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    /// Resolves the working directory for an observed OpenCode process,
    /// preferring an explicit project argument and falling back to the captured
    /// launch cwd / `PWD`.
    public func workingDirectory(observed: VaultObservedAgentProcess) -> String? {
        let fallbackWorkingDirectory = Self.normalized(
            observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
        )
        return projectWorkingDirectory(
            observed: observed,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        ) ?? fallbackWorkingDirectory
    }

    /// Resolves the working directory implied by an explicit OpenCode project
    /// argument, relative to a fallback working directory when the project path
    /// is not absolute.
    public func projectWorkingDirectory(
        observed: VaultObservedAgentProcess,
        fallbackWorkingDirectory: String?
    ) -> String? {
        guard let project = projectArgument(in: launchTail(observed: observed)) else {
            return nil
        }
        return resolvedProjectPath(project, fallbackWorkingDirectory: fallbackWorkingDirectory)
    }

    /// Extracts the positional project argument from an OpenCode argument tail,
    /// skipping options (and their values) and known subcommand names.
    public func projectArgument(in arguments: [String]) -> String? {
        let commandNames: Set<String> = [
            "completion",
            "acp",
            "mcp",
            "attach",
            "run",
            "debug",
            "providers",
            "auth",
            "agent",
            "upgrade",
            "uninstall",
            "serve",
            "web",
            "models",
            "stats",
            "export",
            "import",
            "github",
            "pr",
            "session",
            "plugin",
            "plug",
            "db"
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? arguments[nextIndex] : nil
            }
            if argument.hasPrefix("-") {
                index += optionWidth(arguments, index: index)
                continue
            }
            return commandNames.contains(argument) ? nil : argument
        }
        return nil
    }

    /// Computes how many argument tokens a single OpenCode option consumes
    /// (1 for flags / `=`-joined values, 2 for value-taking options, and a
    /// variadic span for `--cors`).
    public func optionWidth(_ arguments: [String], index: Int) -> Int {
        guard index < arguments.count else { return 1 }
        let argument = arguments[index]
        if argument.contains("=") {
            return 1
        }
        let valueOptions: Set<String> = [
            "--log-level",
            "--port",
            "--hostname",
            "--mdns-domain",
            "--cors",
            "--model",
            "-m",
            "--session",
            "-s",
            "--prompt",
            "--agent"
        ]
        guard valueOptions.contains(argument),
              index + 1 < arguments.count else {
            return 1
        }
        if argument == "--cors" {
            var end = index + 1
            while end < arguments.count, !arguments[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private func resolvedProjectPath(
        _ rawValue: String,
        fallbackWorkingDirectory: String?
    ) -> String? {
        guard let project = Self.normalized(rawValue) else { return nil }
        let expandedProject = (project as NSString).expandingTildeInPath
        if expandedProject.hasPrefix("/") {
            return (expandedProject as NSString).standardizingPath
        }
        guard let fallbackWorkingDirectory = Self.normalized(fallbackWorkingDirectory) else {
            return (expandedProject as NSString).standardizingPath
        }
        return URL(fileURLWithPath: fallbackWorkingDirectory, isDirectory: true)
            .appendingPathComponent(expandedProject)
            .standardizedFileURL
            .path
    }

    private func executablePath(
        named name: String,
        environment: [String: String]
    ) -> String? {
        let executableName = (name as NSString).lastPathComponent
        guard !executableName.isEmpty else { return nil }
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(path), isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
