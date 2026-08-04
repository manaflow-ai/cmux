public import CmuxAgentReplica
import Foundation

/// Describes the journal id decision for a successive transcript identity.
public enum JournalDecision: Hashable, Sendable {
    /// The transcript identity still belongs to the existing journal.
    case same(JournalID)
    /// The transcript identity requires a newly minted journal.
    case created(JournalID)
}
