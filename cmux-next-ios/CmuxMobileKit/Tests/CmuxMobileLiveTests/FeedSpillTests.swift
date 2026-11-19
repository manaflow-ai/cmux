import CmuxMobileModel
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
    /// disk; before the spill they were dropped (`olderOnDisk` stays 0 without one). What the
    /// Feed holds in memory (`residentBytes`) with and without the spill stays about the same:
    /// the spill keeps at most one partial page in memory.
    ///
    /// It measures the store, not the process: malloc's bytes in use for the whole process
    /// counted whatever other tests allocated meanwhile (the hybrid proofs: 80 MB against a 76 MB
    /// bound), which the 16 MB `neighbor` below stands for. The inserts drive `FeedStore`, which
    /// is main-actor code; they give the main actor back after every event, so the 3 to 9 s each
    /// run takes in a debug build holds the other main-actor tests for one insert (1 to 3 ms) at
    /// a time. Its store has its own memory pressure, so another test's (or the system's) memory
    /// warning cannot trim it mid-run. Not every 50: a 50-event
    /// chunk is 50 to 150 ms on the iOS simulator, ahead of every main-actor hop of the tests
    /// running beside it (ReconnectChainTimingTests counted 9 to 11 round trips of 80 ms where
    /// it allows 3: run 44237359613, and feat-cmux-next run 44236368758 after #45716).
    @Test func memoryWithSpill() async {
        func run(spilling: Bool) async -> (live: Int, onDisk: Int) {
            let store = FeedStore(items: [], memoryPressure: MemoryPressure(observesSystem: false))
            let spill = Self.spill()
            if spilling { store.useSpill(spill) }
            for index in 0..<3000 {
                store.insert(Self.item(index, bytes: 8192), atTop: true)
                await Task.yield()
            }
            // What another test (the hybrid proofs, say) holds meanwhile is not the Feed's.
            let neighbor = spilling ? Self.neighborAllocation() : []
            spill.flush()
            let live = store.residentBytes()
            withExtendedLifetime(neighbor) {}
            let onDisk = spill.storedCount()
            store.useSpill(nil)
            return (live, onDisk)
        }
        let dropped = await run(spilling: false)
        let spilled = await run(spilling: true)
        let line = "MEMBENCH feed events=3000 body=8KB window=\(FeedStore.memoryLimit) dropped=\(dropped.live >> 10)KB onDisk=\(dropped.onDisk) spilled=\(spilled.live >> 10)KB onDisk=\(spilled.onDisk)"
        print(line)
        Attachment.record(line, named: "membench.txt")
        #expect(dropped.onDisk == 0)
        #expect(spilled.onDisk == 2500)
        // The reading sees the window: 500 events of 8 KB.
        #expect(dropped.live >= FeedStore.memoryLimit * 8192)
        // A partial page (under 100 events of 8 KB) and the spilled ids, at most.
        #expect(spilled.live < dropped.live + 2 << 20)
    }

    /// 16 MB that another test allocates and holds while this one measures: a guard against going
    /// back to a process-wide reading (malloc's bytes in use), which counts it and fails.
    static func neighborAllocation() -> [UInt8] {
        [UInt8](repeating: 0xA5, count: 16 << 20)
    }

}
