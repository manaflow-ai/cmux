import Foundation

/// One complete row's bytes and its stable position within the journal.
struct WorkstreamJournalLine {
    let data: Data
    let offset: UInt64
}
