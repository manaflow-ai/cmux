@testable import CmuxNextFeed
import Foundation
import Testing

/// The Mac's local feed owner (GitHub's items) and the reports basket keep a bounded
/// window, as the daemon's feed owner does (`cmux-feed-core` `MAX_ITEMS`): a GitHub poll
/// every two minutes, or a mailbox read from its start, no longer grows them for as long
/// as the app runs.
@MainActor
struct FeedLocalOwnerBoundTests {
    private func notice(_ index: Int, read: Bool = false) -> FeedItem {
        FeedItem(id: "fi_\(index)", home: .local(install: "github"), title: "GitHub", body: "#\(index)",
                 dedupeKey: "github:notification:\(index)", poster: FeedPoster(kind: .agent, label: "GitHub"),
                 readAt: read ? Date(timeIntervalSince1970: 1) : nil, createdAt: Date(timeIntervalSince1970: Double(1_000 + index)))
    }

    @Test func theLocalOwnerKeepsItsNewestItemsAndEveryOpenRequest() {
        let source = InMemoryFeedSource(snapshot: FeedSnapshot(revision: 0, user: "u", device: "Mac", items: []))
        let model = FeedModel(source: source)
        model.start()
        let request = FeedItem(id: "fi_req", title: "Allow make?", prompt: .question(.init(question: "Ship?")),
                               poster: FeedPoster(kind: .agent, label: "Agent"), createdAt: Date(timeIntervalSince1970: 0))
        source.post(request)
        source.post(notice(-1, read: true))
        let limit = InMemoryFeedSource.defaultMaxItems
        for index in 0..<(limit * 3) { source.post(notice(index, read: index % 2 == 0 && index < limit)) }
        #expect(source.itemIDs.count == limit)
        #expect(source.itemIDs.contains("fi_req"))
        #expect(source.itemIDs.contains("fi_\(limit * 3 - 1)"))
        #expect(!source.itemIDs.contains("fi_0"))
        #expect(!source.itemIDs.contains("fi_-1"))
        // The model follows the owner's removals.
        #expect(model.confirmed.count == limit)
        #expect(Set(model.confirmed.keys) == source.itemIDs)
    }

    @Test func theReportsBasketShowsTheNewestReports() {
        let model = FeedModel(source: InMemoryFeedSource(snapshot: FeedSnapshot(revision: 0, user: "u", device: "Mac", items: [])))
        let reports = (0..<(FeedModel.reportsLimit * 5)).map {
            FeedReport(id: "r\($0)", sender: "host/a", body: "report \($0)", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        model.replaceReports(reports)
        #expect(model.reports.count == FeedModel.reportsLimit)
        #expect(model.reports.first?.id == "r\(FeedModel.reportsLimit * 5 - 1)")
        #expect(model.reports.last?.id == "r\(FeedModel.reportsLimit * 4)")
    }
}
