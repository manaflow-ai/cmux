public import CmuxAgentReplica
import Foundation

/// Captures one process-observation sample supplied by the app adapter.
public struct ProcessObservation: Hashable, Sendable {
    /// The observed process identifier.
    public let pid: Int32
    /// The observed parent process identifier.
    public let ppid: Int32
    /// The process start identity tick used to distinguish reused pids.
    public let startTick: Int
    /// A short argv summary for display and diagnostics.
    public let argvSummary: String
    /// The best-effort agent kind inferred from process metadata.
    public let agentKindGuess: AgentKind
    /// The observed current working directory.
    public let cwd: String
    /// The stable cmux surface id, when known.
    public let surfaceID: String?
    /// The transcript path held open by the process, when known.
    public let openTranscriptPath: String?

    /// Creates a process observation.
    /// - Parameters:
    ///   - pid: The process identifier.
    ///   - ppid: The parent process identifier.
    ///   - startTick: The process start identity tick.
    ///   - argvSummary: A short argv summary.
    ///   - agentKindGuess: The inferred agent kind.
    ///   - cwd: The current working directory.
    ///   - surfaceID: The stable cmux surface id, when known.
    ///   - openTranscriptPath: The transcript path held open by the process, when known.
    public init(
        pid: Int32,
        ppid: Int32,
        startTick: Int,
        argvSummary: String,
        agentKindGuess: AgentKind,
        cwd: String,
        surfaceID: String?,
        openTranscriptPath: String?
    ) {
        self.pid = pid
        self.ppid = ppid
        self.startTick = startTick
        self.argvSummary = argvSummary
        self.agentKindGuess = agentKindGuess
        self.cwd = cwd
        self.surfaceID = surfaceID
        self.openTranscriptPath = openTranscriptPath
    }
}
