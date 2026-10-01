import Foundation

/// Starts a detached acpmux daemon and returns its WebSocket endpoint from
/// the `--ready-fd` line, so a fresh daemon needs no status round trip.
///
/// The daemon runs as a background job of a throwaway `/bin/sh` with job
/// control on (`set -m`), so it gets its own process group, is adopted by
/// launchd when the shell exits, and outlives the app (its sessions are
/// durable state). Its fd 3 is our pipe; stdout and stderr go to
/// `<home>/daemon.log`.
nonisolated enum AcpmuxDaemonLauncher {
    nonisolated enum Failure: Error, Equatable {
        case spawnFailed(String)
        /// The daemon exited before it was ready; its log says why.
        case exited(logPath: String)
        /// Ready, but without a WebSocket listener (the port was taken).
        case noWebSocket(logPath: String)
    }

    static let script = #"set -m; "$@" 3>&1 1>>"$ACPMUX_LAUNCH_LOG" 2>&1 </dev/null &"#

    static func arguments(for environment: AcpmuxEnvironment) -> [String] {
        ["-c", script, "acpmux-launch", environment.executable.path, "daemon", "run", "--ready-fd", "3"]
            + environment.daemonArguments
    }

    @concurrent static func launch(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(20)) async throws -> AcpmuxWebEndpoint {
        try FileManager.default.createDirectory(at: environment.home, withIntermediateDirectories: true)
        let pipe = Pipe()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = arguments(for: environment)
        var variables = ProcessInfo.processInfo.environment.merging(environment.childEnvironment) { $1 }
        variables["ACPMUX_LAUNCH_LOG"] = environment.logPath
        shell.environment = variables
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
        } catch {
            throw Failure.spawnFailed(String(describing: error))
        }
        // Only the shell and the daemon may hold the write end, so EOF means both are gone.
        try? pipe.fileHandleForWriting.close()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        defer { try? pipe.fileHandleForReading.close() }
        let line: String
        do {
            line = try await withAgentPaneDeadline(deadline, label: "acpmux start") { try await reader.firstLine() }
        } catch AgentPaneLineReader.Failure.endOfFile {
            throw Failure.exited(logPath: environment.logPath)
        }
        guard let ready = AcpmuxReadyLine.parse(line) else { throw Failure.exited(logPath: environment.logPath) }
        guard let webURL = ready.webUrl, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw Failure.noWebSocket(logPath: environment.logPath)
        }
        return endpoint
    }
}
