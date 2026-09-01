public import CmuxCore
public import Foundation

/// Describes whether a terminal respawn stays local or must cross a remote
/// persistent-PTY boundary.
public enum RemotePTYRespawnRouting: Equatable, Sendable {
    /// The surface is not owned by a remote persistent PTY.
    case local
    /// The surface can be respawned through the SSH PTY bridge.
    case persistentSSH
    /// The surface is remote-owned, but its transport cannot provide the SSH
    /// persistent-PTY bridge required for a safe respawn.
    case unsupportedRemote
}

/// Pure launch and lifecycle inputs for one remote PTY respawn.
public struct RemotePTYRespawnPlan: Equatable, Sendable {
    /// Fresh daemon-side persistent PTY session identifier.
    public let sessionID: String
    /// Previously mapped daemon session that should be cleaned up, if any.
    public let previousSessionID: String?
    /// Trimmed command supplied by the respawn request.
    public let rawCommand: String
    /// Command delivered to the remote daemon, including an optional remote
    /// working-directory change.
    public let remoteCommand: String

    /// Creates a respawn plan from already selected lifecycle identities.
    ///
    /// - Parameters:
    ///   - sessionID: Fresh daemon-side session identifier.
    ///   - previousSessionID: Replaced daemon session, when one is tracked.
    ///   - rawCommand: Command supplied by the caller.
    ///   - remoteCommand: Command to execute on the remote host.
    public init(
        sessionID: String,
        previousSessionID: String?,
        rawCommand: String,
        remoteCommand: String
    ) {
        self.sessionID = sessionID
        self.previousSessionID = previousSessionID
        self.rawCommand = rawCommand
        self.remoteCommand = remoteCommand
    }
}

/// Builds remote PTY routing decisions and shell-safe command payloads without
/// depending on AppKit, terminal views, or workspace lifecycle state.
public struct RemotePTYRespawnPlanner: Sendable {
    /// Creates a stateless planner.
    public init() {}

    /// Classifies a surface using only its ownership bit and remote
    /// configuration.
    ///
    /// - Parameters:
    ///   - isRemoteOwned: Whether the surface is currently remote-owned.
    ///   - configuration: Remote configuration associated with the workspace.
    /// - Returns: The routing decision for the respawn operation.
    public func routing(
        isRemoteOwned: Bool,
        configuration: WorkspaceRemoteConfiguration?
    ) -> RemotePTYRespawnRouting {
        guard isRemoteOwned else { return .local }
        guard let configuration,
              configuration.transport == .ssh,
              configuration.terminalTransport == .ssh,
              configuration.preserveAfterTerminalExit,
              configuration.persistentDaemonSlot != nil,
              !configuration.skipDaemonBootstrap else {
            return .unsupportedRemote
        }
        return .persistentSSH
    }

    /// Builds a validated command plan for a persistent SSH respawn.
    ///
    /// - Parameters:
    ///   - sessionID: Fresh daemon-side session identifier.
    ///   - rawCommand: Command supplied by the respawn request.
    ///   - remoteWorkingDirectory: Optional directory in the remote namespace.
    ///   - previousSessionID: Replaced daemon session, when one is tracked.
    /// - Returns: A plan, or `nil` when the command or session ID is empty.
    public func plan(
        sessionID: String,
        rawCommand: String,
        remoteWorkingDirectory: String?,
        previousSessionID: String?
    ) -> RemotePTYRespawnPlan? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty, !trimmedCommand.isEmpty else { return nil }

        let trimmedWorkingDirectory = remoteWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteCommand: String
        if let trimmedWorkingDirectory, !trimmedWorkingDirectory.isEmpty {
            remoteCommand = "cd \(Self.shellSingleQuoted(trimmedWorkingDirectory)) && \(trimmedCommand)"
        } else {
            remoteCommand = trimmedCommand
        }
        let normalizedPreviousSessionID = previousSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RemotePTYRespawnPlan(
            sessionID: trimmedSessionID,
            previousSessionID: normalizedPreviousSessionID?.isEmpty == false
                ? normalizedPreviousSessionID
                : nil,
            rawCommand: trimmedCommand,
            remoteCommand: remoteCommand
        )
    }

    /// Returns the stable default session identifier used by SSH PTY bridges.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace identity encoded in the session name.
    ///   - panelID: Panel identity encoded in the session name.
    /// - Returns: A normalized `ssh-<workspace>-<panel>` identifier.
    public static func defaultSessionID(workspaceID: UUID, panelID: UUID) -> String {
        "ssh-\(workspaceID.uuidString)-\(panelID.uuidString)"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
