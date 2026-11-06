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
        let store = FeedStore(items: (0..<300).map { Self.item($0) })
        MemoryPressure.shared.relieve()
        #expect(store.items.count == FeedStore.pressureLimit)
    }

    /// 20,000 events of 8 KB arriving live: the Feed's memory stays at its window either way;
    /// the spill keeps the rest readable from disk instead of dropping them.
    @Test func memoryWithSpill() async {
        let store = FeedStore(items: [])
        let spill = Self.spill()
        store.useSpill(spill)
        let start = Self.footprint()
        var peak = start
        for index in 0..<20_000 {
            store.insert(Self.item(index, bytes: 8192), atTop: true)
            if index % 1000 == 0 { peak = max(peak, Self.footprint()) }
        }
        let onDisk = spill.storedCount()
        print("MEMBENCH feed events=20000 body=8KB held=\(store.items.count) growth=+\((peak &- start) >> 20)MB onDisk=\(onDisk)")
        #expect(store.items.count == FeedStore.memoryLimit)
        #expect(onDisk == 19_500)
        store.useSpill(nil)
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
