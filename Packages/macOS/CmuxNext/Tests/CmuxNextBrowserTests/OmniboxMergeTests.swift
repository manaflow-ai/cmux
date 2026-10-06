@testable import CmuxNextBrowser
import Foundation
import Testing

/// The merge rule over random cards, highlights and phase B arrival orders:
/// no row at or above the highlight moves, the card never loses a row (its
/// height never shrinks), rows fill free slots before replacing, a
/// replacement only takes a lower-ranked row below the highlight, and no
/// page shows twice.
nonisolated struct OmniboxMergeTests {
    static func row(_ index: Int, kind: BrowserSuggestion.Kind, score: Double) -> BrowserSuggestion {
        kind == .search
            ? BrowserSuggestion(kind: .search, title: "query \(index)", detail: "", url: URL(string: "https://s.example/?q=\(index)")!, score: score)
            : BrowserSuggestion(kind: kind, title: "Page \(index)", detail: "", url: URL(string: "https://p\(index).example/")!, score: score)
    }

    @Test func randomArrivalsNeverMoveRowsAtOrAboveTheHighlight() {
        var random = SeededGenerator(seed: 110)
        for _ in 0..<400 {
            let capacity = Int.random(in: 3...10, using: &random)
            let count = Int.random(in: 1...capacity, using: &random)
            var rows = (0..<count).map { Self.row($0, kind: $0 == 0 ? .search : .history, score: Double.random(in: 150...999, using: &random)) }
            let highlight = Int.random(in: 0..<count, using: &random)
            // Phase B batches in a random order, some repeating earlier rows.
            let pool = (0..<12).map { Self.row(100 + $0, kind: .search, score: Double.random(in: 100...900, using: &random)) }
                + [rows[rows.count - 1]]
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let batch = Array(pool.shuffled(using: &random).prefix(Int.random(in: 1...5, using: &random)))
                let before = rows
                rows = OmniboxMerge.merge(visible: before, highlight: highlight, incoming: batch, capacity: capacity)
                #expect(Array(rows.prefix(highlight + 1)) == Array(before.prefix(highlight + 1)), "rows at or above the highlight stay")
                #expect(rows.count >= before.count, "the card never shrinks")
                #expect(rows.count <= max(capacity, before.count))
                #expect(Set(rows.map(OmniboxMerge.key)).count == rows.count, "one row per page or query")
                for index in before.indices where index > highlight && rows[index] != before[index] {
                    #expect(rows.count >= capacity, "a replacement only when the card is full")
                    #expect(rows[index].score > before[index].score, "a replacement outranks the row it takes")
                }
                for index in rows.indices.dropFirst(before.count) {
                    #expect(batch.contains(rows[index]), "new slots hold new rows")
                }
            }
        }
    }

    @Test func freeSlotsFillInRankOrderThenTheLowestRowBelowIsReplaced() {
        let visible = [Self.row(0, kind: .search, score: 1000), Self.row(1, kind: .history, score: 600), Self.row(2, kind: .history, score: 180)]
        let incoming = [Self.row(10, kind: .search, score: 190), Self.row(11, kind: .search, score: 199), Self.row(12, kind: .search, score: 200)]
        let merged = OmniboxMerge.merge(visible: visible, highlight: 0, incoming: incoming, capacity: 4)
        // 200 fills the free slot; 199 takes the 180 row's place; 190 outranks nothing left below.
        #expect(merged.map(\.title) == ["query 0", "Page 1", "query 11", "query 12"])
        // With the highlight on the 180 row, it stays.
        let held = OmniboxMerge.merge(visible: visible, highlight: 2, incoming: incoming, capacity: 4)
        #expect(held.map(\.title) == ["query 0", "Page 1", "Page 2", "query 12"])
    }
}
