import CmuxAgentGUIProjection

struct TranscriptUnreadTracker: Sendable {
    private var newestVisibleRowID: TranscriptRowID?

    mutating func unreadCount(
        rows: [TranscriptRow],
        visibleRowIDs: Set<TranscriptRowID>
    ) -> Int {
        let indexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.rowID, $0) })
        if let candidate = visibleRowIDs.min(by: {
            (indexes[$0] ?? .max) < (indexes[$1] ?? .max)
        }), let candidateIndex = indexes[candidate] {
            if let existingID = newestVisibleRowID, let existingIndex = indexes[existingID] {
                if candidateIndex < existingIndex {
                    newestVisibleRowID = candidate
                }
            } else {
                newestVisibleRowID = candidate
            }
        }
        guard let newestVisibleRowID, let boundary = indexes[newestVisibleRowID] else {
            return 0
        }
        return rows[..<boundary].filter(\.isUnread).count
    }
}
