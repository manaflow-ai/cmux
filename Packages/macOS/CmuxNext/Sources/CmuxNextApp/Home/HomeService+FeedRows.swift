import CmuxHomeCore
import CmuxNextCompat
import CmuxNextFeed

extension HomeService {
    /// Keeps the default Chief's transcript showing the Feed's open notices (``HomeFeedRow``: lines for
    /// the person only, never sent to the Chief), following the Feed, which Chief is the default and
    /// Settings > Chief > Show the Feed in Chief (`home.feedInChief`, on by default). Leo 2026-10-20:
    /// "we don't necessarily want to bother the chief with lots of TMI type information, but we want
    /// to make it like easily accessible ... you can opt out if you want".
    func observeFeedRows() {
        // task-owner: lives as long as the service; event-driven (Observation)
        feedRowsObservation = Task { [weak self] in
            for await (rows, conversation) in ObservationStream({ [weak self] () -> ([HomeFeedRow], String?) in
                guard let self, services.settings?.snapshot.homeFeedInChief ?? true else { return ([], nil) }
                // Requests (approvals, questions) stay in the Feed, where they can be answered.
                let notices = services.feed.model.visibleItems.lazy.filter { $0.type == .notice && !$0.isArchived }
                return (notices.prefix(HomeFeedRow.limit).map {
                    HomeFeedRow(id: $0.id, source: $0.poster.label, title: $0.title, url: $0.context.url, date: $0.createdAt)
                }, defaultChiefConversation)
            }) {
                self?.homeStore.setFeedRows(rows, in: conversation.map { CmuxHomeCore.ConversationID($0) })
            }
        }
    }
}
