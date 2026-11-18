import CmuxVisibleRows
import Foundation
import Testing

/// `ListIDDiff` at 100 and 10,000 ids: replaying it as a table does (remove, then insert) gives the new order, kept
/// rows map to their own old row, and one keystroke's diff costs microseconds against a 16 ms frame. Each timing
/// prints a `list-id-diff` line.
struct ListIDDiffTests {
    static func ids(_ n: Int) -> [String] { (0..<n).map { "item\($0)" } }

    /// The keystrokes typing makes: the same results, the first row gone, a row in the middle gone, two rows swapped,
    /// every other row kept in reverse with a new one, and a ranked re-sort of a third of them.
    static func cases(_ n: Int) -> [(String, [String])] {
        let all = ids(n)
        var swapped = all
        swapped.swapAt(1, 3)
        var middle = all
        middle.remove(at: n / 2)
        var resorted = all.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        resorted.sort { $0.hashValue < $1.hashValue }
        return [
            ("same", all),
            ("drop-first", Array(all.dropFirst())),
            ("drop-middle", middle),
            ("swap-two", swapped),
            ("reshuffle", all.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).reversed() + ["new"]),
            ("re-rank-third", resorted),
        ]
    }

    /// `old` with the diff applied as NSTableView applies it: removals by old index, then insertions by new index.
    static func replay(_ old: [String], _ new: [String], _ diff: ListIDDiff) -> [String] {
        var rows = old
        for i in diff.removed.reversed() { rows.remove(at: i) }
        for i in diff.inserted { rows.insert(new[i], at: i) }
        return rows
    }

    @Test(arguments: [100, 10_000])
    func replayingTheDiffGivesTheNewOrder(n: Int) throws {
        let old = Self.ids(n)
        for (name, new) in Self.cases(n) {
            let diff = try #require(ListIDDiff.between(old, new), "\(name)")
            #expect(Self.replay(old, new, diff) == new, "\(name)")
            for (i, o) in diff.oldIndex.enumerated() where o >= 0 { #expect(old[o] == new[i], "\(name) row \(i)") }
        }
    }

    @Test(arguments: [100, 10_000])
    func smallChangesTouchFewRows(n: Int) throws {
        let old = Self.ids(n)
        let same = try #require(ListIDDiff.between(old, old))
        #expect(same.removed.isEmpty && same.inserted.isEmpty && same.hashed == 0 && same.compared == n)
        let dropFirst = try #require(ListIDDiff.between(old, Array(old.dropFirst())))
        #expect(dropFirst.removed == [0] && dropFirst.inserted.isEmpty && dropFirst.hashed == 1)
        var swapped = old
        swapped.swapAt(1, 3)
        let swap = try #require(ListIDDiff.between(old, swapped))
        #expect(swap.moved == 2 && swap.removed.count == 2 && swap.inserted.count == 2 && swap.hashed == 6)
    }

    @Test func onlyChangedShownRowsAreReconfigured() throws {
        let old = Self.ids(100)
        var new = Array(old.dropFirst())
        new.insert("fresh", at: 3)
        let diff = try #require(ListIDDiff.between(old, new))
        // Rows 0...11 are shown; item5 (new row 5) changed its text; row 3 is inserted, so never reconfigured.
        let rows = diff.rowsToReconfigure(0..<12) { o, _ in old[o] == "item5" }
        #expect(rows == [5])
        #expect(diff.rowsToReconfigure(0..<12) { _, _ in true } == Array(0..<12).filter { $0 != 3 })
    }

    @Test func aRepeatedOrMissingMatchReloads() {
        #expect(ListIDDiff.between(["a", "b", "c"], ["a", "x", "x", "c"]) == nil)
        #expect(ListIDDiff.between(["a"], ["b"]) == nil)
        #expect(ListIDDiff.between([String](), ["a"]) == nil)
    }

    /// The diff of one keystroke over 10,000 ids, median and p95 over 50 runs of each case.
    @Test func diffOf10000IdsFitsFarUnderAFrame() throws {
        let n = 10_000
        let old = Self.ids(n)
        let clock = ContinuousClock()
        var worstP95 = 0.0
        for (name, new) in Self.cases(n) {
            var samples: [Double] = []
            var hashed = 0, compared = 0
            for _ in 0..<50 {
                var diff: ListIDDiff?
                let elapsed = clock.measure { diff = ListIDDiff.between(old, new) }
                hashed = diff?.hashed ?? -1
                compared = diff?.compared ?? -1
                samples.append(Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12)
            }
            samples.sort()
            let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
            worstP95 = max(worstP95, p95)
            print("list-id-diff n=\(n) case=\(name) hashed=\(hashed) compared=\(compared) median=\(Int(samples[samples.count / 2])) us "
                + "p95=\(Int(p95)) us")
        }
        // One frame is 16,000 us; the diff must leave the frame to drawing.
        #expect(worstP95 < 8_000, "worst p95 \(worstP95) us")
    }
}
