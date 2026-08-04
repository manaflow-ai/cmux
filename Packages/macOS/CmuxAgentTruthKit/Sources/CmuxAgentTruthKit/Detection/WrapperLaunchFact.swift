public import CmuxAgentReplica
import Foundation

/// Captures one launch observation produced by a cmux wrapper.
public struct WrapperLaunchFact: Hashable, Sendable {
    /// The stable cmux surface id that launched the process.
    public let surfaceID: String
    /// The launched agent kind.
    public let agentKind: AgentKind
    /// The process identifier that will become the real agent process after `exec`.
    public let pid: Int32
    /// The launch working directory.
    public let cwd: String
    /// The real or wrapper-minted session id, when the wrapper knows one.
    public let sessionID: AgentSessionID?
    /// The launch argv category.
    public let launchArgvKind: LaunchArgvKind
    /// Whether the wrapper observed the cmux socket as unavailable at launch.
    public let socketWasDown: Bool
    /// Whether the wrapper knows hooks are explicitly unavailable by safe mode.
    public let hooksUnavailableSafeMode: Bool
    /// The observed CLI version, when the wrapper can supply it.
    public let cliVersion: String?
    /// The minimum CLI version required for full capability, when known.
    public let minimumCLIVersion: String?

    /// Creates a wrapper launch fact.
    ///
    /// If ``sessionID`` is absent, the reducer may create a wrapper-path provisional
    /// id using the fold tick because wrappers do not carry a process start tick.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable cmux surface id.
    ///   - agentKind: The agent kind.
    ///   - pid: The process identifier.
    ///   - cwd: The launch working directory.
    ///   - sessionID: The session id, when known.
    ///   - launchArgvKind: The launch argv category.
    ///   - socketWasDown: Whether the wrapper reported a socket-down launch.
    ///   - hooksUnavailableSafeMode: Whether hooks are explicitly unavailable by safe mode.
    ///   - cliVersion: The observed CLI version.
    ///   - minimumCLIVersion: The minimum CLI version for full capability.
    public init(
        surfaceID: String,
        agentKind: AgentKind,
        pid: Int32,
        cwd: String,
        sessionID: AgentSessionID?,
        launchArgvKind: LaunchArgvKind,
        socketWasDown: Bool = false,
        hooksUnavailableSafeMode: Bool = false,
        cliVersion: String? = nil,
        minimumCLIVersion: String? = nil
    ) {
        self.surfaceID = surfaceID
        self.agentKind = agentKind
        self.pid = pid
        self.cwd = cwd
        self.sessionID = sessionID
        self.launchArgvKind = launchArgvKind
        self.socketWasDown = socketWasDown
        self.hooksUnavailableSafeMode = hooksUnavailableSafeMode
        self.cliVersion = cliVersion
        self.minimumCLIVersion = minimumCLIVersion
    }
}
