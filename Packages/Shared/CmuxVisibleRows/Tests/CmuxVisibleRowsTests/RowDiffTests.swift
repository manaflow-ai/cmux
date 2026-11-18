import CmuxVisibleRows
import Testing

/// `RowDiff`, the id diff the macOS Files tree and Find results apply to their tables, with no view (it builds on
/// Linux): one changed, added or removed row touches that row only, at 100 and 10,000 rows. Each case prints one
/// `row-diff` line with the median µs per update over 31 runs.
@Suite struct RowDiffTests {
    struct Row: Equatable {
        var id: Int
        var text: String
    }

    static func rows(_ count: Int) -> [Row] { (0..<count).map { Row(id: $0, text: "f\($0)") } }

    static func diff(_ old: [Row], _ new: [Row]) -> RowDiff { RowDiff.between(old, new, id: \.id, limit: 2_000) }

    /// Median µs of `run` over 31 runs, printed as `row-diff <case> N=<count> <µs>us`.
    static func time(_ label: String, _ count: Int, _ run: () -> RowDiff) {
        var samples: [Duration] = []
        for _ in 0..<31 { samples.append(ContinuousClock().measure { _ = run() }) }
        let mid = samples.sorted()[15].components
        print("row-diff \(label) N=\(count) \(Int(mid.seconds) * 1_000_000 + Int(mid.attoseconds / 1_000_000_000_000))us")
    }

    @Test(arguments: [100, 10_000])
    func unchangedRowsTouchNothing(count: Int) {
        let old = Self.rows(count)
        #expect(Self.diff(old, old) == .update(removed: [], inserted: [], changed: []))
        Self.time("unchanged", count) { Self.diff(old, old) }
    }

    @Test(arguments: [100, 10_000])
    func oneChangedRowReloadsThatRowOnly(count: Int) {
        let old = Self.rows(count)
        var new = old
        new[count / 2].text = "changed"
        #expect(Self.diff(old, new) == .update(removed: [], inserted: [], changed: [count / 2]))
        Self.time("one-change", count) { Self.diff(old, new) }
    }

    @Test(arguments: [100, 10_000])
    func oneInsertedRowInsertsThatRowOnly(count: Int) {
        let old = Self.rows(count)
        var new = old
        new.insert(Row(id: -1, text: "new"), at: 3)
        #expect(Self.diff(old, new) == .update(removed: [], inserted: [3], changed: []))
        Self.time("one-insert", count) { Self.diff(old, new) }
    }

    @Test(arguments: [100, 10_000])
    func oneRemovedRowRemovesThatRowOnly(count: Int) {
        let old = Self.rows(count)
        var new = old
        new.remove(at: 1)
        #expect(Self.diff(old, new) == .update(removed: [1], inserted: [], changed: []))
        Self.time("one-remove", count) { Self.diff(old, new) }
    }

    @Test(arguments: [100, 10_000])
    func aMoveAndAChangeTogetherTouchOnlyThoseRows(count: Int) {
        let old = Self.rows(count)
        var new = old
        new.remove(at: 0)
        new.insert(Row(id: -1, text: "new"), at: 5)
        new[count - 1].text = "changed"
        #expect(Self.diff(old, new) == .update(removed: [0], inserted: [5], changed: [count - 1]))
    }

    @Test func noRowKeptOrTooManyChangesReloadsWhole() {
        let old = Self.rows(100)
        #expect(Self.diff(old, old.map { Row(id: $0.id + 1_000, text: $0.text) }) == .reloadAll)
        let big = Self.rows(10_000)
        #expect(Self.diff(big, Array(big.prefix(5_000))) == .reloadAll)
        #expect(Self.diff([], old) == .reloadAll)
    }
}
