import CmuxAgentReplica
import Foundation

enum AgentGUIJournalPipelineEvent: Hashable, Sendable {
    case reset(journalID: JournalID, tailSeq: EntrySeq)
    case appended(journalID: JournalID, entries: [EntrySnapshot])
    case replaced(journalID: JournalID, entry: EntrySnapshot)
}
