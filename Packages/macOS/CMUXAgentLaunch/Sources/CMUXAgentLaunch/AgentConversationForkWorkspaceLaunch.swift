public import CmuxCore

/// The resolved launch descriptor for forking an agent conversation into a brand
/// new workspace.
///
/// Faithful lift of the value type the app-target `Workspace` god object nested
/// as `Workspace.AgentConversationForkWorkspaceLaunch`. It is a pure `Equatable`
/// payload produced by the workspace's `forkAgentWorkspaceLaunch(...)` resolver
/// and consumed by the new-workspace fork path (which hands the fields to
/// `TabManager.addWorkspace(...)` and, when present, `configureRemoteConnection`).
///
/// The fork *orchestration* stays app-side: it drives the live bonsplit split
/// tree, terminal-surface creation, and `TabManager`, none of which belong in
/// this package. Only this descriptor lifts, so the produced value crosses the
/// app/package seam as a typed payload rather than an app-owned nested type.
///
/// `WorkspaceRemoteConfiguration` is the `CmuxCore` Sendable value type, so this
/// descriptor depends only downward (Wave-2 `CmuxCore` leaf) and the package
/// graph stays acyclic. The app target keeps a `typealias` so every existing
/// `Workspace.AgentConversationForkWorkspaceLaunch` reference resolves unchanged.
public struct AgentConversationForkWorkspaceLaunch: Equatable {
    /// The resolved working directory for the forked conversation, used both for
    /// the local-terminal cwd and (on a remote fork) the post-connect directory.
    public var workingDirectory: String?
    /// The cwd passed to the new workspace's terminal, or `nil` on a remote fork
    /// where the directory is applied after the SSH connection is established.
    public var terminalWorkingDirectory: String?
    /// The startup command for the new workspace's terminal (the remote SSH
    /// startup command on a remote fork, otherwise the resolved fork command).
    public var initialTerminalCommand: String?
    /// The startup input piped into the forked conversation (the agent's own
    /// `--resume --fork-session` invocation).
    public var initialTerminalInput: String
    /// The environment applied to the new workspace's terminal (the remote SSH
    /// startup environment on a remote fork, otherwise empty).
    public var initialTerminalEnvironment: [String: String]
    /// The remote connection configuration to apply to the new workspace, or
    /// `nil` for a local fork.
    public var remoteConfiguration: WorkspaceRemoteConfiguration?
    /// Whether the new workspace should auto-connect its remote configuration.
    public var autoConnectRemoteConfiguration: Bool

    /// Creates a fork-launch descriptor. Mirrors the lifted nested type's
    /// implicit memberwise initializer so the app-side resolver constructs it
    /// byte-identically.
    public init(
        workingDirectory: String?,
        terminalWorkingDirectory: String?,
        initialTerminalCommand: String?,
        initialTerminalInput: String,
        initialTerminalEnvironment: [String: String],
        remoteConfiguration: WorkspaceRemoteConfiguration?,
        autoConnectRemoteConfiguration: Bool
    ) {
        self.workingDirectory = workingDirectory
        self.terminalWorkingDirectory = terminalWorkingDirectory
        self.initialTerminalCommand = initialTerminalCommand
        self.initialTerminalInput = initialTerminalInput
        self.initialTerminalEnvironment = initialTerminalEnvironment
        self.remoteConfiguration = remoteConfiguration
        self.autoConnectRemoteConfiguration = autoConnectRemoteConfiguration
    }
}
