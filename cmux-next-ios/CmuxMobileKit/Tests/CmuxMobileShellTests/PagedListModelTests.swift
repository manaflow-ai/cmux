import Foundation
import Testing
@testable import CmuxMobileDesign

/// The shared list's order and paging guards (verify/paged-list.md, "Paging guards" and "Memory"):
/// the linked order, one read per edge, a refresh asked twice read once, a refresh's stale answers
/// dropped, a repeated cursor or a run of empty pages stopped, repeated ids shown once, and a
/// windowed model that keeps only its window in memory and reads the rest back from disk.
struct PagedListOrderTests {
    @Test func insertsMovesAndRemovesAnywhere() {
        var order = PagedListOrder<Int>()
        for id in 1...5 { order.append(id) }
        order.insertAtHead(0)
        #expect(order.all() == [0, 1, 2, 3, 4, 5])
        let inserted = order.insert(9, after: 2)
        #expect(inserted)
        #expect(order.all() == [0, 1, 2, 9, 3, 4, 5])
        // A member moves.
        order.insert(5, after: 0)
        #expect(order.all() == [0, 5, 1, 2, 9, 3, 4])
        order.insertAtHead(4)
        #expect(order.all() == [4, 0, 5, 1, 2, 9, 3])
        order.remove(4)
        order.remove(3)
        order.remove(42)
        #expect(order.all() == [0, 5, 1, 2, 9])
        #expect(order.head == 0 && order.tail == 9 && order.count == 5)
        let afterMissing = order.insert(7, after: 42)
        let afterItself = order.insert(1, after: 1)
        #expect(!afterMissing, "an anchor not in the list")
        #expect(!afterItself, "a row after itself")
        #expect(order.ids(from: 5, count: 3) == [5, 1, 2])
        #expect(order.ids(from: 2, count: 10) == [2, 9])
        #expect(order.walkBack(from: 2, steps: 2) == 5)
        #expect(order.walkBack(from: 5, steps: 10) == 0)
        for id in order.all() { order.remove(id) }
        #expect(order.isEmpty && order.head == nil && order.tail == nil)
    }
}

@MainActor
struct PagedListModelGuardTests {
    struct Row: Identifiable, Equatable, Sendable, Codable {
        let id: Int
        var text = ""
    }

    /// A scripted source: each cursor's page, and the cursors read in order.
    @MainActor final class Script {
        var pages: [String: PagedListPage<Row>] = [:]
        var reads: [String] = []
        /// Reads that wait until `release` (a read in flight).
        var held: Set<String> = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

        func page(_ cursor: String?) async throws -> PagedListPage<Row> {
            let key = cursor ?? "first"
            reads.append(key)
            if held.contains(key) {
                await withCheckedContinuation { waiting[key, default: []].append($0) }
            }
            guard let page = pages[key] else { throw CancellationError() }
            return page
        }

        func release(_ key: String) {
            held.remove(key)
            waiting.removeValue(forKey: key)?.forEach { $0.resume() }
        }

        /// Lets a held read reach its continuation.
        func waitUntilHeld(_ key: String) async {
            for _ in 0..<1000 where waiting[key] == nil { await Task.yield() }
        }
    }

    static func rows(_ range: ClosedRange<Int>) -> [Row] { range.map { Row(id: $0) } }

    /// Lets every disk read queued so far land. The spill answers in order on one queue, and its
    /// stats come back to the main queue after the reads queued before them; a read that lands can
    /// queue another, so a few rounds.
    func drain(_ model: PagedListModel<Row>) async {
        for _ in 0..<4 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                model.spillStats { _, _, _ in done.resume() }
            }
        }
    }

    @Test func aRepeatedCursorStopsTheEdge() async {
        let script = Script()
        script.pages = ["first": PagedListPage(items: Self.rows(0...9), nextCursor: "a"),
                        "a": PagedListPage(items: Self.rows(10...19), nextCursor: "a")]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        await model.loadMore()
        #expect(model.edge == .end)
        #expect(model.stoppedLoops == 1)
        await model.loadMore()
        #expect(script.reads == ["first", "a"], "the edge read a cursor it already read")
        #expect(model.items.map(\.id) == Array(0...19))
    }

    @Test func aRunOfEmptyPagesStopsTheEdge() async {
        let script = Script()
        script.pages["first"] = PagedListPage(items: Self.rows(0...9), nextCursor: "0")
        for n in 0..<20 { script.pages[String(n)] = PagedListPage(items: [], nextCursor: String(n + 1)) }
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        for _ in 0..<20 { await model.loadMore() }
        #expect(model.edge == .end)
        #expect(model.stoppedLoops == 1)
        #expect(script.reads.count == 1 + PagedListModel<Row>.emptyPageLimit)
    }

    @Test func oneOlderReadAtATime() async {
        let script = Script()
        script.pages = ["first": PagedListPage(items: Self.rows(0...9), nextCursor: "a"),
                        "a": PagedListPage(items: Self.rows(10...19), nextCursor: nil)]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        script.held = ["a"]
        let first = Task { await model.loadMore() }
        await script.waitUntilHeld("a")
        #expect(model.edge == .loading)
        await model.loadMore()
        await model.loadMore()
        script.release("a")
        await first.value
        #expect(script.reads == ["first", "a"], "a second read of the same edge started")
        #expect(model.edge == .end)
    }

    @Test func aRefreshAskedTwiceReadsOnce() async {
        let script = Script()
        script.pages["first"] = PagedListPage(items: Self.rows(0...9), nextCursor: nil)
        script.held = ["first"]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        let one = Task { await model.loadFirst() }
        await script.waitUntilHeld("first")
        let two = Task { await model.loadFirst() }
        for _ in 0..<50 { await Task.yield() }
        script.release("first")
        await one.value
        await two.value
        #expect(script.reads == ["first"])
        #expect(model.items.count == 10)
    }

    @Test func aRefreshDropsTheOlderPageItReplaced() async {
        let script = Script()
        script.pages = ["first": PagedListPage(items: Self.rows(0...9), nextCursor: "a"),
                        "a": PagedListPage(items: Self.rows(10...19), nextCursor: "b")]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        script.held = ["a"]
        let older = Task { await model.loadMore() }
        await script.waitUntilHeld("a")
        // The source changed: the refresh's first page has nothing in common with the rows shown.
        script.pages["first"] = PagedListPage(items: Self.rows(100...109), nextCursor: "z")
        await model.loadFirst()
        script.release("a")
        await older.value
        #expect(model.items.map(\.id) == Array(100...109), "a page the refresh replaced landed")
        #expect(model.edge == .more)
    }

    @Test func repeatedIdsShowOnce() async {
        let script = Script()
        script.pages = ["first": PagedListPage(items: [Row(id: 0), Row(id: 1), Row(id: 1), Row(id: 2)], nextCursor: "a"),
                        "a": PagedListPage(items: [Row(id: 2), Row(id: 3)], nextCursor: nil)]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        await model.loadMore()
        #expect(model.items.map(\.id) == [0, 1, 2, 3])
        model.receiveNewest([Row(id: -1), Row(id: -1)])
        #expect(model.items.map(\.id) == [-1, 0, 1, 2, 3])
        #expect(model.total == 5)
    }

    @Test func aFirstPageReadAgainKeepsTheOlderRows() async {
        let script = Script()
        script.pages = ["first": PagedListPage(items: Self.rows(0...9), nextCursor: "a"),
                        "a": PagedListPage(items: Self.rows(10...19), nextCursor: "b")]
        let model = PagedListModel<Row>(direction: .down) { try await script.page($0) }
        await model.loadFirst()
        await model.loadMore()
        // Row 3 went, a new row came, row 5 changed.
        var fresh = [Row(id: -1)] + Self.rows(0...9).filter { $0.id != 3 }
        fresh[5] = Row(id: 5, text: "edited")
        script.pages["first"] = PagedListPage(items: fresh, nextCursor: "a")
        await model.loadFirst()
        #expect(model.items.map(\.id) == [-1, 0, 1, 2, 4, 5, 6, 7, 8, 9] + Array(10...19))
        #expect(model.items.first { $0.id == 5 }?.text == "edited")
        #expect(script.reads == ["first", "a", "first"], "the refresh read the older pages again")
    }

    @Test func aWindowKeepsItsRowsInMemoryAndTheRestOnDisk() async {
        let script = Script()
        for page in 0..<5 {
            let key = page == 0 ? "first" : String(page)
            script.pages[key] = PagedListPage(items: Self.rows(page * 200...page * 200 + 199), nextCursor: page < 4 ? String(page + 1) : nil)
        }
        let model = PagedListModel<Row>(direction: .down, memory: .window(200)) { try await script.page($0) }
        await model.loadFirst()
        for _ in 0..<60 where model.edge != .end {
            // Read toward the older end, as a reader scrolling would.
            if let last = model.items.last { model.reading(last.id) }
            await model.loadMore()
            await drain(model)
        }
        #expect(model.total == 1000)
        #expect(model.valuesInMemory <= 200, "\(model.valuesInMemory) values in memory with a window of 200")
        let onDisk = await withCheckedContinuation { done in model.spillStats { onDisk, _, _ in done.resume(returning: onDisk) } }
        #expect(onDisk >= 800, "only \(onDisk) rows on disk")
        // Back to the newest rows: read back from disk.
        model.showNewest()
        await drain(model)
        #expect(model.items.first?.id == 0, "the newest rows did not come back from disk")
        #expect(model.newerEdge == .end)
        #expect(model.valuesInMemory <= 200)
    }

    /// The list asks for the next rows on every scroll step near the edge: asking twice before the
    /// first answer lands must not move the window twice, past the row being read.
    @Test func askingTwiceMovesTheWindowOnce() async {
        let script = Script()
        script.pages["first"] = PagedListPage(items: Self.rows(0...399), nextCursor: nil)
        let model = PagedListModel<Row>(direction: .down, memory: .window(120)) { try await script.page($0) }
        await model.loadFirst()
        model.reading(100)
        await drain(model)
        #expect(model.items.contains { $0.id == 100 })
        await model.loadMore()
        await model.loadMore()
        await drain(model)
        #expect(model.items.contains { $0.id == 100 }, "the window moved past the row being read")
        #expect(model.items.contains { $0.id == 180 }, "the window did not move toward the older rows")
        // Asked again with the rows back: the reader is already a quarter window from the newer side.
        let shown = model.items.map(\.id)
        await model.loadMore()
        await drain(model)
        #expect(model.items.map(\.id) == shown, "asking again moved the window")
    }

    /// An edit that lands while the row's disk read runs is newer than what the read returns.
    @Test func anEditDuringADiskReadWins() async {
        let script = Script()
        script.pages["first"] = PagedListPage(items: Self.rows(0...399), nextCursor: nil)
        let model = PagedListModel<Row>(direction: .down, memory: .window(120)) { try await script.page($0) }
        await model.loadFirst()
        // No awaits from here: the read of rows 120...159 stays in flight.
        model.reading(100)
        model.update(Row(id: 150, text: "edited while read"))
        // Row 150 leaves the window (its edit goes to disk), then comes back while the read still runs.
        model.showNewest()
        model.reading(100)
        await drain(model)
        await drain(model)
        #expect(model.items.first { $0.id == 150 }?.text == "edited while read", "the disk's older value replaced the edit")
    }

    @Test func anEditToARowOnDiskComesBackEdited() async {
        let script = Script()
        script.pages["first"] = PagedListPage(items: Self.rows(0...399), nextCursor: nil)
        let model = PagedListModel<Row>(direction: .down, memory: .window(120)) { try await script.page($0) }
        await model.loadFirst()
        #expect(model.items.first?.id == 0)
        // Row 300 is on disk; an edit to it lands there, and reading it back shows the edit.
        model.update(Row(id: 300, text: "edited on disk"))
        model.reading(model.items.last?.id)
        for _ in 0..<40 where !model.items.contains(where: { $0.id == 300 }) {
            model.reading(model.items.last?.id)
            await model.loadMore()
            await drain(model)
        }
        #expect(model.items.first { $0.id == 300 }?.text == "edited on disk")
    }
}
