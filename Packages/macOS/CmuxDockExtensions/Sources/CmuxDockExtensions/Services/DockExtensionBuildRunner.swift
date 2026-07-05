import Foundation

/// Runs a manifest's build steps at install/update time.
///
/// Each step's argv is shell-quoted and `exec`'d through the user's login
/// shell (`$SHELL -l -c 'exec …'`) so toolchains resolve with the user's real
/// PATH — a GUI app's inherited environment doesn't have it. Mirrors herdr's
/// build contract: steps run from the extension root, in manifest order, a
/// failure aborts the install, and no cmux runtime/socket environment is
/// passed (every inherited `CMUX_*` variable is stripped).
public actor DockExtensionBuildRunner {
    /// Default wall-clock limit per build step.
    public static let defaultStepTimeout = Duration.seconds(600)

    private let runner: DockExtensionProcessRunner
    private let loginShellPath: @Sendable () -> String

    /// Creates the runner.
    ///
    /// - Parameters:
    ///   - runner: Subprocess runner (injectable for tests).
    ///   - loginShellPath: Login shell resolver; the default uses `$SHELL`
    ///     when executable, then `/bin/zsh`, then `/bin/sh`.
    public init(
        runner: DockExtensionProcessRunner = DockExtensionProcessRunner(),
        loginShellPath: (@Sendable () -> String)? = nil
    ) {
        self.runner = runner
        self.loginShellPath = loginShellPath ?? { Self.defaultLoginShell() }
    }

    /// Runs every step in order from `root`, appending combined output to a
    /// timestamped log file under `logsDirectory`.
    ///
    /// - Throws: ``DockExtensionError/buildFailed(command:exitCode:logTail:)``
    ///   or ``DockExtensionError/buildTimedOut(command:)`` on the first
    ///   failing step.
    public func runBuildSteps(
        _ steps: [DockExtensionBuildStep],
        in root: URL,
        logsDirectory: URL,
        stepTimeout: Duration = DockExtensionBuildRunner.defaultStepTimeout
    ) async throws {
        guard !steps.isEmpty else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let logURL = logsDirectory.appendingPathComponent("build-\(timestamp).log", isDirectory: false)
        var log = ""

        for step in steps {
            let display = step.shellCommand
            log += "$ \(display)\n"
            let result: DockExtensionProcessResult
            do {
                result = try await run(step: step, in: root, timeout: stepTimeout)
            } catch {
                log += "spawn failed: \(error.localizedDescription)\n"
                try? log.write(to: logURL, atomically: true, encoding: .utf8)
                throw DockExtensionError.buildFailed(
                    command: display,
                    exitCode: -1,
                    logTail: error.localizedDescription
                )
            }
            log += result.standardOutput
            if !result.standardError.isEmpty {
                log += result.standardError
            }
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
            if result.timedOut {
                throw DockExtensionError.buildTimedOut(command: display)
            }
            guard result.exitStatus == 0 else {
                throw DockExtensionError.buildFailed(
                    command: display,
                    exitCode: result.exitStatus,
                    logTail: Self.tail(result.standardError.isEmpty ? result.standardOutput : result.standardError)
                )
            }
        }
    }

    private func run(
        step: DockExtensionBuildStep,
        in root: URL,
        timeout: Duration
    ) async throws -> DockExtensionProcessResult {
        // Build steps get the user's environment minus every cmux runtime
        // variable (herdr parity: build commands see no runtime/socket env).
        let environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CMUX_") }
        let shellCommand = "exec " + step.shellCommand
        return try await runner.run(
            executableURL: URL(fileURLWithPath: loginShellPath()),
            arguments: ["-l", "-c", shellCommand],
            currentDirectoryURL: root,
            environment: environment,
            timeout: timeout
        )
    }

    /// `$SHELL` when it points at an executable, then `/bin/zsh` (the macOS
    /// default), then `/bin/sh`.
    public static func defaultLoginShell() -> String {
        let fileManager = FileManager.default
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           !shell.isEmpty, fileManager.isExecutableFile(atPath: shell) {
            return shell
        }
        if fileManager.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        return "/bin/sh"
    }

    private static func tail(_ text: String, limit: Int = 2000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + trimmed.suffix(limit)
    }
}
