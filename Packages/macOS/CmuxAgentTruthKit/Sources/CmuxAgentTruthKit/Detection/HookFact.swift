public import CmuxAgentReplica
import Foundation

/// Captures one hook event emitted by an agent integration.
public struct HookFact: Hashable, Sendable {
    /// The agent session id carried by the hook.
    public let sessionID: AgentSessionID
    /// The normalized hook event name.
    public let eventName: HookEventName
    /// The stable cmux surface id, when carried by the hook.
    public let surfaceID: String?
    /// The transcript path, when carried by the hook.
    public let transcriptPath: String?
    /// The working directory, when carried by the hook.
    public let cwd: String?
    /// The process identifier, when carried by the hook.
    public let pid: Int32?
    /// Whether a notification represents an ask that needs user input.
    public let notificationRequiresInput: Bool
    /// Whether this hook reports that hooks are explicitly unavailable by safe mode.
    public let hooksUnavailableSafeMode: Bool
    /// The observed CLI version, when the hook can supply it.
    public let cliVersion: String?
    /// The minimum CLI version required for full capability, when known.
    public let minimumCLIVersion: String?

    /// Creates a hook fact.
    /// - Parameters:
    ///   - sessionID: The session id.
    ///   - eventName: The normalized hook event.
    ///   - surfaceID: The surface id, when known.
    ///   - transcriptPath: The transcript path, when known.
    ///   - cwd: The working directory, when known.
    ///   - pid: The process identifier, when known.
    ///   - notificationRequiresInput: Whether a notification is an ask.
    ///   - hooksUnavailableSafeMode: Whether hooks are explicitly unavailable by safe mode.
    ///   - cliVersion: The observed CLI version.
    ///   - minimumCLIVersion: The minimum CLI version for full capability.
    public init(
        sessionID: AgentSessionID,
        eventName: HookEventName,
        surfaceID: String?,
        transcriptPath: String?,
        cwd: String?,
        pid: Int32?,
        notificationRequiresInput: Bool = false,
        hooksUnavailableSafeMode: Bool = false,
        cliVersion: String? = nil,
        minimumCLIVersion: String? = nil
    ) {
        self.sessionID = sessionID
        self.eventName = eventName
        self.surfaceID = surfaceID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.pid = pid
        self.notificationRequiresInput = notificationRequiresInput
        self.hooksUnavailableSafeMode = hooksUnavailableSafeMode
        self.cliVersion = cliVersion
        self.minimumCLIVersion = minimumCLIVersion
    }
}
