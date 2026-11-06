import CmuxMobileModel
import Darwin
import Foundation
import Testing
@testable import CmuxMobileFeed

/// Events past the Feed's 500-event window wait on disk while the app runs and come back when
/// the person scrolls to the end; a memory warning trims the Feed further. Before, events that
/// left the window were gone until a relaunch read the 200-event archive.
@MainActor
@Suite(.serialized) struct FeedSpillTests {
    static func item(_ index: Int, ask: Bool = false, bytes: Int = 4) -> FeedItem {
        let kind: FeedItem.Kind = ask ? .needsInput : .finished
        return FeedItem(id: "e\(index)", kind: kind, workspaceID: "w1", tabID: "t", agentName: "Codex", harness: "codex",
                        workspaceTitle: "cmux", markdown: "event \(index) " + String(repeating: "x", count: bytes), quote: nil,
                        createdAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)))
    }

    static func spill() -> RowSpill<FeedItem> {
        RowSpill(directory: FileManager.default.temporaryDirectory.appending(path: "feedspill-\(UUID().uuidString)"), pageSize: 100)
    }

    @Test func eventsPastTheWindowComeBackFromDisk() async {
        let store = FeedStore(items: [])
        store.useSpill(Self.spill())
        for index in 0..<800 { store.insert(Self.item(index), atTop: true) }
        #expect(store.items.count == FeedStore.memoryLimit)
        #expect(store.olderOnDisk == 300)
        #expect(store.items.last?.id == "e300")

        await store.loadOlderPage()
        #expect(store.items.count == FeedStore.memoryLimit + 100)
        #expect(store.items.last?.id == "e200")
        while store.olderOnDisk > 0 { await store.loadOlderPage() }
        #expect(store.items.map(\.id) == (0..<800).reversed().map { "e\($0)" })

        // Back at the top: the window goes back to 500, the rest back to disk.
        store.restoreWindow()
        #expect(store.items.count == FeedStore.memoryLimit)
        #expect(store.olderOnDisk == 300)
        await store.loadOlderPage()
        #expect(store.items.last?.id == "e200")
        store.useSpill(nil)
    }

    /// The Mac re-reports its ledger on every tree change: an event already on disk is not
    /// written there again, and one back in memory is not duplicated when its page returns.
    @Test func reReportedHistoryIsNotSpilledTwice() async {
        let store = FeedStore(items: [])
        store.useSpill(Self.spill())
        let all = (0..<700).map { Self.item($0) }
        store.mergeHistory(all)
        #expect(store.olderOnDisk == 200)
        store.mergeHistory(all)
        store.mergeHistory(all)
        #expect(store.olderOnDisk == 200)
        while store.olderOnDisk > 0 { await store.loadOlderPage() }
        #expect(store.items.count == 700)
        #expect(Set(store.items.map(\.id)).count == 700)
        store.useSpill(nil)
    }

    /// What the person or the Mac did to events while they were on disk holds when they return.
    @Test func readAndRemovedWhileOnDiskHold() async {
        let store = FeedStore(items: [])
        store.useSpill(Self.spill())
        for index in 0..<700 { store.insert(Self.item(index), atTop: true) }
        #expect(store.olderOnDisk == 200)
        store.markRead(["e5"])
        store.remove("e6")
        store.markAllRead()
        while store.olderOnDisk > 0 { await store.loadOlderPage() }
        #expect(store.item(id: "e6") == nil)
        #expect(store.item(id: "e5")?.isRead == true)
        let unread = store.items.filter { !$0.isRead }.count
        #expect(unread == 0)
        #expect(store.items.count == 699)
        store.useSpill(nil)
    }

    /// A page read for one account never lands in the next account's Feed.
    @Test func aPageInFlightDoesNotCrossAccounts() async {
        let store = FeedStore(items: [])
        store.useSpill(Self.spill())
        for index in 0..<700 { store.insert(Self.item(index), atTop: true) }
        store.loadOlder()
        store.clearForSignOut()
        store.useSpill(Self.spill())
        await store.loadOlderPage()
        for _ in 0..<5 { await Task.yield() }
        #expect(store.items.isEmpty)
        store.useSpill(nil)
    }

    @Test func memoryWarningKeepsTheNewestAndEveryOpenAsk() async {
        let store = FeedStore(items: [])
        store.useSpill(Self.spill())
        store.insert(Self.item(0, ask: true), atTop: true)
        for index in 1..<400 { store.insert(Self.item(index), atTop: true) }
        store.relieveMemoryPressure()
        #expect(store.items.count == FeedStore.pressureLimit + 1)
        #expect(store.items.contains { $0.id == "e0" })
        #expect(store.olderOnDisk == 399 - FeedStore.pressureLimit)
        store.useSpill(nil)
    }

    /// The system's warning reaches the Feed through `MemoryPressure`.
    @Test func systemWarningReachesTheFeed() {
        let pressure = MemoryPressure(observesSystem: false)
        let store = FeedStore(items: (0..<300).map { Self.item($0) }, memoryPressure: pressure)
        pressure.relieve()
        #expect(store.items.count == FeedStore.pressureLimit)
    }

    /// 3,000 live events of 8 KB: the Feed holds its window and the spill holds the rest on
    /// disk; before the spill they were dropped (`olderOnDisk` stays 0 without one). Live heap
    /// bytes (malloc's size in use) with and without the spill stay about the same: the
    /// spill keeps at most one partial page in memory.
    @Test func memoryWithSpill() async {
        func run(spilling: Bool) -> (live: Int, onDisk: Int) {
            let store = FeedStore(items: [])
            let spill = Self.spill()
            if spilling { store.useSpill(spill) }
            let start = Self.heapInUse()
            for index in 0..<3000 { store.insert(Self.item(index, bytes: 8192), atTop: true) }
            spill.flush()
            let live = Self.heapInUse() - start
            let onDisk = spill.storedCount()
            store.useSpill(nil)
            return (live, onDisk)
        }
        let dropped = run(spilling: false)
        let spilled = run(spilling: true)
        let line = "MEMBENCH feed events=3000 body=8KB window=\(FeedStore.memoryLimit) dropped=\(dropped.live >> 10)KB onDisk=\(dropped.onDisk) spilled=\(spilled.live >> 10)KB onDisk=\(spilled.onDisk)"
        print(line)
        Attachment.record(line, named: "membench.txt")
        #expect(dropped.onDisk == 0)
        #expect(spilled.onDisk == 2500)
        // A partial page (under 100 events of 8 KB) and the spilled ids, at most.
        #expect(spilled.live < dropped.live + 2 << 20)
    }

    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

}
