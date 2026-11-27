import Foundation

extension HomeStore {
    /// Shows `rows` in `conversation`'s transcript (the main Chief's), in place of any rows shown
    /// before, in it or another conversation; nil or no rows shows none. The rows are the person's
    /// only: nothing is sent, so the Chief never reads them (``HomeFeedRow``).
    public func setFeedRows(_ rows: [HomeFeedRow], in conversation: ConversationID?) {
        let target = rows.isEmpty ? nil : conversation
        let held = feedRows
        guard held?.conversation != target || (held?.rows ?? []) != (target == nil ? [] : rows) else { return }
        feedRows = target.map { (conversation: $0, rows: rows) }
        if let old = held?.conversation { bumpTranscript(old) }
        if let target, target != held?.conversation { bumpTranscript(target) }
    }
}
