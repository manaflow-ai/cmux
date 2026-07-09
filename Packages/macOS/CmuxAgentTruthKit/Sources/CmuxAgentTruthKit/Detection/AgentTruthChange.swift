public import CmuxAgentReplica
import Foundation

/// Describes the externally visible changes emitted by the truth reducer.
public enum AgentTruthChange: Hashable, Sendable {
    /// A session snapshot was inserted or replaced.
    case sessionUpserted(AgentSessionSnapshot)
    /// A session snapshot was removed.
    case sessionRemoved(AgentSessionID)
}
