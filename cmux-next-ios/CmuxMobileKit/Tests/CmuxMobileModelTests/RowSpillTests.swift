import CmuxMobileModel
import Foundation
import Testing

/// Rows a list drops from memory wait on disk and come back newest page first, in order.
@Suite struct RowSpillTests {
    struct Row: Codable, Equatable, Sendable { var id: Int }

    func spill(pageSize: Int = 10, maxRows: Int = 1000) -> RowSpill<Row> {
        RowSpill(directory: FileManager.default.temporaryDirectory.appending(path: "rowspill-\(UUID().uuidString)"),
                 pageSize: pageSize, maxRows: maxRows)
    }

    @Test func pagesComeBackNewestFirstInOrder() async {
        let spill = spill()
        defer { spill.reset() }
        // A list evicts its oldest rows first: 0..<25 (newest first), then 25..<40 above them.
        spill.push((0..<25).reversed().map(Row.init))
        spill.push((25..<40).reversed().map(Row.init))
        #expect(spill.storedCount() == 40)
        var back: [Int] = []
        while true {
            let page = await spill.pop()
            if page.isEmpty { break }
            #expect(page.count <= 10)
            back += page.map(\.id)
        }
        #expect(back == Array((0..<40).reversed()))
        #expect(spill.storedCount() == 0)
    }

    /// One row at a time writes whole pages (no page rewrite per row); the newest rows short of
    /// a page wait in memory and come back first.
    @Test func singleRowEvictionsFillPages() async throws {
        let spill = spill(pageSize: 5)
        defer { spill.reset() }
        for id in 0..<12 { spill.push([Row(id: id)]) }
        #expect(spill.storedCount() == 12)
        let files = try FileManager.default.contentsOfDirectory(atPath: spill.directory.path)
        #expect(files.count == 2)
        #expect(await spill.pop().map(\.id) == [11, 10])
        #expect(await spill.pop().map(\.id) == [9, 8, 7, 6, 5])
    }

    /// Past its cap the spill drops its oldest pages, as the list did before it had one.
    @Test func capDropsTheOldestPages() async {
        let spill = spill(pageSize: 10, maxRows: 30)
        defer { spill.reset() }
        spill.push((0..<100).reversed().map(Row.init))
        #expect(spill.storedCount() == 30)
        #expect(await spill.pop().first?.id == 99)
    }

    @Test func resetEmptiesIt() async {
        let spill = spill()
        spill.push([Row(id: 1)])
        spill.reset()
        #expect(await spill.pop().isEmpty)
    }

    @MainActor @Test func memoryPressureRunsLiveHandlersOnly() {
        let pressure = MemoryPressure(observesSystem: false)
        final class Owner { var calls = 0 }
        var owner: Owner? = Owner()
        let counter = Owner()
        pressure.register(owner!) { counter.calls += 1 }
        pressure.relieve()
        #expect(counter.calls == 1)
        owner = nil
        pressure.relieve()
        #expect(counter.calls == 1)
        #expect(pressure.registeredCount == 0)
    }
}
