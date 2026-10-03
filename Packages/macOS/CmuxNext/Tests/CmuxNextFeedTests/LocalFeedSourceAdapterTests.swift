@testable import CmuxNextFeed
import Foundation
import Testing

@Suite @MainActor
struct LocalFeedSourceAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_791_039_600)

    @Test func bootstrapAndReconnectKeepBothOwnerSnapshots() {
        let cloudItem = item("cloud", home: .cloud)
        let localItem = item("local", home: .local(install: "test"))
        let primary = AdapterTestSource(items: [cloudItem])
        let local = MockFeedSource(snapshot: FeedSnapshot(revision: 0, user: "usr_test", device: "Mac", items: [localItem]))
        let model = FeedModel(source: LocalFeedSourceAdapter(primary: primary, local: local))
        model.start()
        #expect(Set(model.confirmed.keys) == [cloudItem.id, localItem.id])
        primary.emit(.snapshot(FeedSnapshot(revision: 3, user: "usr_test", device: "Mac", items: [cloudItem])))
        #expect(Set(model.confirmed.keys) == [cloudItem.id, localItem.id])
    }

    @Test func mixedReadWaitsForEveryOwnerBeforeRemovingOverlay() {
        let cloudItem = item("cloud", home: .cloud)
        let localItem = item("local", home: .local(install: "test"))
        let primary = AdapterTestSource(items: [cloudItem])
        let local = MockFeedSource(snapshot: FeedSnapshot(revision: 0, user: "usr_test", device: "Mac", items: [localItem]))
        let model = FeedModel(source: LocalFeedSourceAdapter(primary: primary, local: local), clock: { self.now })
        local.echoImmediately = false
        model.start()
        model.markRead([cloudItem.id, localItem.id])
        #expect(primary.sent.first?.items == [cloudItem.id])
        let key = model.pending.first!.key
        local.deliverHeld()
        #expect(model.pending.count == 1)
        #expect(model.item(cloudItem.id)?.readAt == now)
        primary.emit(.settled(key: key, reject: .disconnected))
        #expect(model.pending.isEmpty)
        #expect(model.item(cloudItem.id)?.readAt == nil)
        #expect(model.item(localItem.id)?.readAt == now)
        #expect(model.lastReject == .disconnected)
    }

    private func item(_ id: String, home: FeedHome) -> FeedItem {
        FeedItem(id: id, home: home, title: id, prompt: .notice,
                 poster: FeedPoster(kind: .system, label: "Test"), createdAt: now)
    }
}

@MainActor
private final class AdapterTestSource: FeedPostingSource {
    var items: [FeedItem]
    var sent: [FeedIntent] = []
    var started = false
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?

    init(items: [FeedItem]) { self.items = items }
    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        started = true
        self.sink = sink
        sink(.connection(.connected))
        sink(.snapshot(FeedSnapshot(revision: 0, user: "usr_test", device: "Mac", items: items)))
    }
    func send(_ intent: FeedIntent) { sent.append(intent) }
    func stop() { started = false; sink = nil }
    func post(_ item: FeedItem) { emit(.event(FeedEvent(revision: 1, change: .items([item])))) }
    func emit(_ event: FeedSourceEvent) { sink?(event) }
}
