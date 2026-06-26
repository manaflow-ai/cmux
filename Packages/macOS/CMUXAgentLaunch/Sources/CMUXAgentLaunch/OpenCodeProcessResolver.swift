import Foundation

/// Resolves the launch shape (executable path, preserved argument tail, and
/// working/project directory) for a live, CMUX-scoped OpenCode process from the
/// argv and environment cmux observed for it.
///
/// OpenCode is launched in several spellings (a direct `opencode` binary, a
/// node runtime wrapping an `opencode` script, an explicit `--project <dir>`
/// command), so re-deriving a faithful relaunch command means: picking the real
/// executable (honoring an explicit path, then `PATH` lookup, then the process
/// path, then a bare `opencode`), keeping only the arguments OpenCode itself
/// accepts (via ``AgentLaunchSanitizer``), and recovering the effective working
/// directory from the `--project` positional or the captured launch cwd.
///
/// Used by live-process detection (Sources/VaultAgentProcessScanner.swift) so a
/// CMUX-scoped OpenCode process that cmux never recorded a session hook for can
/// still be resumed/forked with a command that reproduces its launch. The type
/// holds an injected `FileManager` for the `PATH` executable probe; construct
/// one at the call site rather than reaching through a static namespace.
public struct OpenCodeProcessResolver: Sendable {
    /// `FileManager` is not `Sendable`, but `FileManager.default` is documented
    /// as thread-safe and the only value injected here; `nonisolated(unsafe) let`
    /// is the sanctioned escape hatch for an immutable, effectively-Sendable
    /// stored property.
    nonisolated(unsafe) let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter fileManager: Injected so tests can point the `PATH`
    ///   executable probe at a temporary tree; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The executable path to relaunch `observed` with: an explicit path
    /// argument wins, then a `PATH` lookup of an `opencode`-looking argument,
    /// then an `opencode`-looking process path, then a `PATH` lookup of
    /// `opencode`, finally a bare `opencode`.
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
           let resolved = resolveExecutable(named: argumentExecutable, environment: environment) {
            return resolved
        }
        if let processPath = observed.processPath,
           processPath.contains("/"),
           VaultObservedAgentProcess.argumentLooksLikeOpenCode(processPath) {
            return processPath
        }
        if let resolved = resolveExecutable(named: "opencode", environment: environment) {
            return resolved
        }
        return argumentExecutable ?? "opencode"
    }

    /// The relaunch argv (executable plus OpenCode-preserved argument tail), or
    /// `nil` when the tail cannot be sanitized.
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

    /// The arguments following the OpenCode executable token in `observed`'s
    /// argv (the portion to sanitize and preserve for relaunch).
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

    /// The effective working directory for `observed`: the resolved `--project`
    /// target if present, otherwise the captured launch cwd
    /// (`CMUX_AGENT_LAUNCH_CWD`/`PWD`).
    public func workingDirectory(observed: VaultObservedAgentProcess) -> String? {
        let fallbackWorkingDirectory = normalized(
            observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
        )
        return projectWorkingDirectory(
            observed: observed,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        ) ?? fallbackWorkingDirectory
    }

    /// The working directory implied by an OpenCode `--project`/positional
    /// project argument, resolved relative to `fallbackWorkingDirectory`, or
    /// `nil` when no project argument is present.
    public func projectWorkingDirectory(
        observed: VaultObservedAgentProcess,
        fallbackWorkingDirectory: String?
    ) -> String? {
        guard let project = projectArgument(in: launchTail(observed: observed)) else {
            return nil
        }
        return resolvedProjectPath(project, fallbackWorkingDirectory: fallbackWorkingDirectory)
    }

    private func projectArgument(in arguments: [String]) -> String? {
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

    private func optionWidth(_ arguments: [String], index: Int) -> Int {
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
        guard let project = normalized(rawValue) else { return nil }
        let expandedProject = (project as NSString).expandingTildeInPath
        if expandedProject.hasPrefix("/") {
            return (expandedProject as NSString).standardizingPath
        }
        guard let fallbackWorkingDirectory = normalized(fallbackWorkingDirectory) else {
            return (expandedProject as NSString).standardizingPath
        }
        return URL(fileURLWithPath: fallbackWorkingDirectory, isDirectory: true)
            .appendingPathComponent(expandedProject)
            .standardizedFileURL
            .path
    }

    private func resolveExecutable(
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

    private func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
