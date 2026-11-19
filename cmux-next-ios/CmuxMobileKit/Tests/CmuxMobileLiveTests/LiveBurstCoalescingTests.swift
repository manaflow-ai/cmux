@testable import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A busy Mac (45 working agents, a spinner in every terminal title) sends hundreds of events a
/// second. Each one used to reach the store, the lists and the Feed on its own, on the main
/// thread, while the person scrolled (Aziz, 2026-11-18). These pin the coalescing: one
/// publication a display frame, one Feed change per ledger read or batch.
@MainActor
@Suite(.serialized) struct LiveBurstCoalescingTests {
    /// 1000 title changes on 30 workspaces before a frame: nothing reaches the store until the
    /// frame, then one publication with the 30 distinct rows at their newest titles (WS-9, WS-14).
    @Test(.timeLimit(.minutes(1))) func aBurstPublishesOnceAFrame() async throws {
        let daemon = LiveFloodDaemon(load: LiveFloodRig.Load(workspaces: 30))
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(daemon, macID: "mac")
        await sync.refresh()
        await sync.waitForUpdates()
        var frames: [@MainActor () -> Void] = []
        sync.nextFrame = { frames.append($0) }
        var rows: [Set<String>] = []
        var trees = 0
        sync.onRows = { _, ids, _ in rows.append(ids) }
        sync.onTree = { _ in trees += 1 }
        let before = sync.publications
        for round in 0..<1000 {
            sync.handle(.titleChanged(surface: round % 30 + 1, title: "t\(round)"))
        }
        await sync.waitForUpdates()
        #expect(sync.publications == before, "nothing is published before the frame")
        #expect(rows.isEmpty)
        #expect(frames.count == 1, "one frame scheduled for the whole burst")
        for frame in frames { frame() }
        #expect(sync.publications == before + 1)
        #expect(rows.count == 1)
        #expect(trees == 0)
        #expect(rows.first?.count == 30)
        // The newest title of each row (surface 30's last change was round 989).
        let last = sync.tree?.workspaces.first { $0.id == "rig-ws-30" }
        #expect(last?.tabs.first?.title == "t989")
        await sync.daemon?.close()
        await sync.bind(nil, macID: "mac")
    }

    // MARK: Feed (FEED-6)

    static func ledger(_ range: ClosedRange<Int>) -> [String: Any] {
        let rows: [[String: Any]] = range.map { index in
            ["id": "n\(index)", "title": "Codex finished", "body": "turn \(index)", "level": "info", "surface": 1,
             "created_at_ms": 1_700_000_000_000 + index * 1000, "source": "agent", "acknowledged": false]
        }
        return ["ok": true, "data": ["notifications": rows]]
    }

    /// A ledger read that brings 30 new events is one Feed change: one `items` change, one run of
    /// the derived lists and read marks, one `onItemsChange` (each upsert ran all of them).
    @Test func aLedgerReadIsOneFeedChange() {
        let store = FeedStore(items: [])
        let feed = TerminalFeed(store: store)
        feed.treeChanged(TerminalFeedTests.tree(codex: "working"), macID: "mac", connection: 1)
        feed.apply(ledger: Self.ledger(1...5))
        #expect(store.items.count == 5)
        var changes = 0
        store.onItemsChange = { _ in changes += 1 }
        let runs = store.derivedRuns
        feed.apply(ledger: Self.ledger(1...35))
        #expect(store.items.count == 35)
        #expect(changes == 1)
        #expect(store.derivedRuns == runs + 1)
    }

    /// `batch`: many writes, one derived run, one `onItemsChange`, lookups right inside it.
    @Test func aBatchRunsTheDerivedWorkOnce() {
        let store = FeedStore(items: [])
        var changes = 0
        store.onItemsChange = { _ in changes += 1 }
        let runs = store.derivedRuns
        store.batch {
            for index in 0..<100 {
                store.upsert(FeedStoreChurnTests.item("e\(index)", ago: Double(100 - index)), atTop: true)
                #expect(store.item(id: "e\(index)") != nil)
            }
            store.remove("e3")
            store.markRead(["e4", "e5"])
        }
        #expect(changes == 1)
        #expect(store.derivedRuns == runs + 1)
        #expect(store.items.count == 99)
        #expect(store.item(id: "e3") == nil)
        #expect(store.item(id: "e4")?.isRead == true)
        #expect(store.visibleItems.count == 99)
    }

    /// A batch that changes nothing changes nothing.
    @Test func anEmptyBatchIsNoChange() {
        let store = FeedStore(items: [FeedStoreChurnTests.item("a")])
        var changes = 0
        store.onItemsChange = { _ in changes += 1 }
        store.batch { store.upsert(FeedStoreChurnTests.item("a"), atTop: true) }
        #expect(changes == 0)
    }
}
