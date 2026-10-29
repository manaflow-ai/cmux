/// A bounded byte window and the complete rows that fit inside it.
struct WorkstreamJournalTail {
    let lines: [WorkstreamJournalLine]
    let exceededBudget: Bool
    let startOffset: UInt64
    let endOffset: UInt64
}
