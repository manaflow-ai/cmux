@testable import CmuxVisibleRows
import Foundation
import Testing

/// RowSlots and RowKeyDiff at 100 and 10,000 rows, with no UI framework: the rows a viewport reaches stay bounded, a
/// scroll step's range moves by a row, one row's new extent restacks only the rows under it, and a snapshot with one
/// changed row keeps every other candidate. Each case prints one `row-slots` line with its time per update in µs.
@Suite struct RowSlotsTests {
    /// Rows 28 tall, a 600 tall viewport, one viewport of overscan each side (Session Info's panel).
    static let row = 28.0, viewport = 600.0

    static func slots(_ n: Int) -> RowSlots {
        var slots = RowSlots(start: 8)
        slots.reset(Array(repeating: row, count: n))
        return slots
    }

    static func micros(_ runs: Int, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<runs { body() } }
        let (seconds, attoseconds) = elapsed.components
        return (Double(seconds) * 1e6 + Double(attoseconds) / 1e12) / Double(runs)
    }

    @Test(arguments: [100, 10_000])
    func theRangeInViewIsBoundedAndAScrollStepMovesItByARow(rows n: Int) {
        let slots = Self.slots(n)
        let bound = Int((3 * Self.viewport / Self.row).rounded(.up)) + 2
        let middle = min(slots.end / 2, 2_000)
        let range = slots.range(top: middle, height: Self.viewport)
        let stepped = slots.range(top: middle + Self.row, height: Self.viewport)
        #expect(range.count <= bound)
        #expect(stepped.count <= bound)
        if n > bound {
            #expect(stepped.lowerBound - range.lowerBound <= 1)
            #expect(stepped.upperBound - range.upperBound <= 1)
        }
        #expect(slots.index(at: slots.tops[n / 2] + 1) == n / 2)
        var sink = 0
        let us = Self.micros(1_000) { sink &+= slots.range(top: middle, height: Self.viewport).count }
        print("row-slots range n=\(n) rows=\(range.count) bound=\(bound) us_per_update=\(String(format: "%.3f", us)) (\(sink % 2))")
    }

    @Test(arguments: [100, 10_000])
    func oneRowsNewExtentRestacksOnlyTheRowsUnderIt(rows n: Int) {
        var slots = Self.slots(n)
        let before = slots.tops
        let changed = n - 5
        let first = slots.set(changed, extent: 56)
        #expect(first)
        let again = slots.set(changed, extent: 56)
        #expect(!again)
        slots.restack(from: changed)
        #expect(Array(slots.tops[..<(changed + 1)]) == Array(before[..<(changed + 1)]))
        #expect(slots.tops[changed + 1] == before[changed + 1] + 28)
        #expect(slots.end == 8 + Double(n) * Self.row + 28)
        var copy = slots
        let us = Self.micros(1_000) {
            copy.set(changed, extent: copy.extents[changed] == 56 ? 28 : 56)
            copy.restack(from: changed)
        }
        print("row-slots restack-tail n=\(n) rows_restacked=\(n - changed) us_per_update=\(String(format: "%.3f", us))")
    }

    @Test(arguments: [100, 10_000])
    func aSnapshotWithOneChangedRowKeepsEveryOtherCandidate(rows n: Int) {
        let keys = (0..<n).map { "row:\($0)" }
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let old = Dictionary(uniqueKeysWithValues: keys.map { ($0, "+1") })
        var items = Array(repeating: "+1", count: n)
        items[3] = "+2"
        // The candidates: the rows a list has views for, about three viewports, never all N.
        let candidates = Array(keys.prefix(66))
        let kept = RowKeyDiff.unchanged(candidates, old: old, index: index, items: items)
        #expect(kept.count == candidates.count - 1)
        #expect(!kept.contains("row:3"))
        var gone = index
        gone["row:5"] = nil
        #expect(!RowKeyDiff.unchanged(candidates, old: old, index: gone, items: items).contains("row:5"))
        var sink = 0
        let us = Self.micros(1_000) { sink &+= RowKeyDiff.unchanged(candidates, old: old, index: index, items: items).count }
        print("row-slots key-diff n=\(n) compared=\(candidates.count) changed=\(candidates.count - kept.count) us_per_update=\(String(format: "%.3f", us)) (\(sink % 2))")
    }
}
