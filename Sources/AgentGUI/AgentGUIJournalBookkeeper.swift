import CmuxAgentReplica
import Foundation

struct AgentGUIJournalBookkeeper {
    private var versionsBySeq: [EntrySeq: UInt64] = [:]

    mutating func stamp(_ entry: EntrySnapshot) -> AgentGUIStampedEntry {
        let nextVersion = (versionsBySeq[entry.seq] ?? 0) + 1
        versionsBySeq[entry.seq] = nextVersion
        let stamped = EntrySnapshot(
            journalID: entry.journalID,
            seq: entry.seq,
            kind: entry.kind,
            content: entry.content,
            version: EntityVersion(rawValue: nextVersion),
            timestampMilliseconds: entry.timestampMilliseconds
        )
        return AgentGUIStampedEntry(entry: stamped, isReplacement: nextVersion > 1)
    }

    mutating func reset() {
        versionsBySeq.removeAll()
    }
}
