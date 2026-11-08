/// One rendered Vault row, with presentation identity separated from session identity.
///
/// `SessionEntry.id` identifies the underlying session, so overlapping Vault
/// sources can legitimately produce repeated values. SwiftUI `ForEach` requires
/// every rendered occurrence to have a unique identity; otherwise later rows can
/// lose their gestures, including drag initiation.
struct SessionIndexRowSnapshot: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let entryID: SessionEntry.ID
        let occurrence: Int
    }

    let id: ID
    let entry: SessionEntry

    /// Preserves every input occurrence while assigning stable IDs for append-only paging.
    static func rows<Entries: Sequence>(for entries: Entries) -> [SessionIndexRowSnapshot]
    where Entries.Element == SessionEntry {
        var nextOccurrenceByEntryID: [SessionEntry.ID: Int] = [:]
        return entries.map { entry in
            let occurrence = nextOccurrenceByEntryID[entry.id, default: 0]
            nextOccurrenceByEntryID[entry.id] = occurrence + 1
            return SessionIndexRowSnapshot(
                id: ID(entryID: entry.id, occurrence: occurrence),
                entry: entry
            )
        }
    }
}
