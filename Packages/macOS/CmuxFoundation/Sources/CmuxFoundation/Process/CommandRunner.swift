public import Foundation

/// Runs external commands with `Process`, capturing output and honoring an
/// optional deadline.
///
/// This is the production ``CommandRunning``. It resolves bare command names
/// against `PATH`, a bundled `bin` directory, and a set of fallback directories
/// (all injectable for tests), reads `stdout`/`stderr` concurrently so a full
/// pipe buffer cannot deadlock the child, and enforces the timeout with a
/// one-shot timer that terminates (then `SIGKILL`s) the process. Task
/// cancellation follows the same deterministic teardown path.
///
/// ```swift
/// let runner = CommandRunner()
/// let token = await runner.runStandardOutput(
///     directory: ".", executable: "gh", arguments: ["auth", "token"], timeout: 5
/// )
/// ```
public struct CommandRunner: CommandRunning, Sendable {
    /// The default fallback `PATH` directories searched when a command is not on `PATH`.
    public static let defaultFallbackSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]

    /// Creates a command runner.
    /// - Parameters:
    ///   - environment: The environment whose `PATH` is searched; defaults to the process environment.
    ///   - bundledBinPath: An extra directory searched ahead of the fallbacks (the app's
    ///     bundled CLI directory); defaults to `Bundle.main`'s `Contents/Resources/bin`.
    ///   - fallbackSearchDirectories: Directories searched after `PATH` and the bundled bin.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories
    ) {
        self.environment = environment
        self.bundledBinPath = bundledBinPath
        self.fallbackSearchDirectories = fallbackSearchDirectories
    }

    /// Runs `executable` with `arguments` in `directory`, capturing its output.
    ///
    /// Implements ``CommandRunning/run(directory:executable:arguments:timeout:)``:
    /// resolves `executable` against the configured `PATH`/bundled-bin/fallbacks,
    /// drains `stdout`/`stderr` concurrently, and enforces `timeout` with a one-shot
    /// timer that terminates (then `SIGKILL`s) the process. See the protocol for the
    /// full contract. Every capture descriptor is close-on-exec and closes before
    /// this method returns.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name (resolved against `PATH`) or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - timeout: A deadline in seconds; when it elapses the process is terminated
    ///     and the result has ``CommandResult/timedOut`` set. `nil` waits indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let executableURL: URL
        let resolvedArguments: [String]
        if let resolved = resolvedCommandPath(executable: executable) {
            executableURL = URL(fileURLWithPath: resolved)
            resolvedArguments = arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            resolvedArguments = [executable] + arguments
        }
        do {
            let execution = try CommandExecution(
                executableURL: executableURL,
                arguments: resolvedArguments,
                currentDirectoryURL: URL(fileURLWithPath: directory)
            )
            return await execution.run(timeout: timeout)
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }
    }

    /// Resolves `executable` to an absolute path, searching `PATH`, the bundled
    /// bin directory, and the fallback directories. Returns `nil` when nothing
    /// executable is found (the caller then runs it via `/usr/bin/env`).
    ///
    /// Internal rather than private so the resolution policy can be unit-tested
    /// directly with an injected environment and fallback directories.
    func resolvedCommandPath(executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        appendSearchPath(bundledBinPath)
        fallbackSearchDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
