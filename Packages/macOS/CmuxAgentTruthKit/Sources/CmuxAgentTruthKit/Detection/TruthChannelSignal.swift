public import CmuxAgentReplica
import Foundation

/// Represents one observation from exactly one truth channel.
public enum TruthChannelSignal: Hashable, Sendable {
    /// A process observer saw a candidate agent process.
    case processObserved(ProcessObservation, tick: Int)
    /// A process observer saw a previously identified process exit.
    case processGone(pid: Int32, startTick: Int, tick: Int)
    /// A cmux wrapper reported a launch.
    case wrapperLaunched(WrapperLaunchFact, tick: Int)
    /// An agent hook emitted a lifecycle or attention event.
    case hookEvent(HookFact, tick: Int)
    /// Transcript parsing corroborated a lifecycle fact.
    case transcriptCorroboration(sessionID: AgentSessionID, fact: TranscriptCorroborationFact, tick: Int)
}
