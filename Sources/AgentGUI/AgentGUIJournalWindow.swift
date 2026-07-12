import CmuxAgentReplica
import Foundation

struct AgentGUIJournalWindow {
    var journalID: JournalID
    var entriesBySeq: [EntrySeq: EntrySnapshot] = [:]
    var hasMoreBefore = false

    var tailSeq: EntrySeq {
        entriesBySeq.keys.max() ?? EntrySeq(rawValue: 0)
    }

    mutating func reset(journalID: JournalID, entries: [EntrySnapshot], hasMoreBefore: Bool) {
        self.journalID = journalID
        self.entriesBySeq = [:]
        self.hasMoreBefore = hasMoreBefore
        for entry in entries.sorted(by: { $0.seq < $1.seq }) {
            insert(entry)
        }
    }

    mutating func apply(_ entry: EntrySnapshot) {
        insert(entry)
    }

    func page(beforeSeq: EntrySeq?, afterSeq: EntrySeq?, limit: Int) -> [EntrySnapshot] {
        let clampedLimit = max(1, min(limit, AgentGUIConstants.maxEntriesLimit))
        let sorted = entriesBySeq.values.sorted { $0.seq < $1.seq }
        if let beforeSeq {
            return Array(sorted.filter { $0.seq < beforeSeq }.suffix(clampedLimit))
        }
        if let afterSeq {
            return Array(sorted.filter { $0.seq > afterSeq }.prefix(clampedLimit))
        }
        return Array(sorted.suffix(clampedLimit))
    }

    func hasMoreBefore(for entries: [EntrySnapshot]) -> Bool {
        guard let first = entries.first, let minimumSeq = entriesBySeq.keys.min() else {
            return hasMoreBefore
        }
        return first.seq > minimumSeq || hasMoreBefore
    }

    private mutating func insert(_ entry: EntrySnapshot) {
        entriesBySeq[entry.seq] = entry
        while entriesBySeq.count > AgentGUIConstants.journalWindowEntryCap, let oldest = entriesBySeq.keys.min() {
            entriesBySeq.removeValue(forKey: oldest)
            hasMoreBefore = true
        }
    }
}
