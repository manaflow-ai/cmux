import Foundation

/// Argument vector and environment for the `__codex-teams-watch` helper that
/// `cmux codex-teams` keeps running beside the root Codex process.
public struct CodexTeamsWatcherInvocation: Sendable, Equatable {
    /// Environment key the CLI resolves the socket password from when no
    /// `--password` flag is given.
    public static let socketPasswordEnvironmentKey = "CMUX_SOCKET_PASSWORD"

    /// Arguments passed after the cmux executable.
    public let arguments: [String]
    /// Environment for the watcher process.
    public let environment: [String: String]

    /// Builds the watcher invocation.
    ///
    /// - Parameters:
    ///   - socketPath: The cmux control socket the watcher connects to.
    ///   - workspaceID: The workspace that owns the root Codex surface.
    ///   - surfaceID: The root Codex surface.
    ///   - appServerURL: The Codex app-server WebSocket URL.
    ///   - codexPath: The Codex executable subagents launch.
    ///   - launchPath: The `PATH` subagents launch with.
    ///   - maxAutoDepth: The deepest subagent level opened automatically.
    ///   - ownerPID: The root Codex process the watcher exits with, if known.
    ///   - socketPassword: The explicit socket password the launcher received.
    ///   - environment: The launcher environment the watcher inherits.
    public init(
        socketPath: String,
        workspaceID: String,
        surfaceID: String,
        appServerURL: String,
        codexPath: String,
        launchPath: String,
        maxAutoDepth: Int,
        ownerPID: Int32?,
        socketPassword: String?,
        environment: [String: String]
    ) {
        var arguments = [
            "--socket",
            socketPath,
            "__codex-teams-watch",
            "--workspace-id",
            workspaceID,
            "--surface-id",
            surfaceID,
            "--app-server-url",
            appServerURL,
            "--codex-path",
            codexPath,
            "--launch-path",
            launchPath,
            "--max-auto-depth",
            String(maxAutoDepth),
        ]
        // The password travels only in the environment: other local users can
        // read a process's arguments, but not its environment.
        var environment = environment
        if let socketPassword,
           !socketPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment[Self.socketPasswordEnvironmentKey] = socketPassword
        }
        if let ownerPID {
            arguments += ["--owner-pid", String(ownerPID)]
        }
        self.arguments = arguments
        self.environment = environment
    }
}
