import CmuxVisibleRows
import Testing

/// The Cloud Team sessions list's math with no UI, at 100 and 10,000 rows: the mounted range stays the viewport plus
/// one viewport each side wherever the list is scrolled, and a remount configures only the rows whose item changed.
/// Each case prints one `fixed-row-window` line with its µs per update.
@Suite struct FixedRowWindowTests {
    static let rowHeight = 26.0, viewportRows = 8
    static var viewport: Double { rowHeight * Double(viewportRows) }
    static let updates = 200

    struct Row: Equatable { var key: String, title: String }

    static func rows(_ count: Int) -> [Row] { (0..<count).map { Row(key: "s\($0)", title: "session \($0)") } }

    static func range(_ count: Int, top: Double, height: Double = viewport) -> Range<Int> {
        FixedRowWindow.range(count: count, top: top, height: height, rowHeight: rowHeight, fallbackHeight: viewport)
    }

    static func window(_ rows: [Row], _ range: Range<Int>) -> [(key: String, item: Row)] {
        rows[range].map { (key: $0.key, item: $0) }
    }

    static func mounted(_ rows: [Row], _ range: Range<Int>) -> [String: Row] {
        Dictionary(uniqueKeysWithValues: rows[range].map { ($0.key, $0) })
    }

    static func microsPerUpdate(_ body: (Int) -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure { for step in 0..<updates { body(step) } }
        let (seconds, attoseconds) = elapsed.components
        return (Double(seconds) * 1e6 + Double(attoseconds) / 1e12) / Double(updates)
    }

    static func line(_ name: String, _ count: Int, _ fields: String, _ micros: Double) {
        print("fixed-row-window case=\(name) n=\(count) \(fields) us_per_update=\((micros * 100).rounded() / 100)")
    }

    @Test(arguments: [100, 10_000])
    func theMountedRangeIsTheViewportAndOverscanAtEveryOffset(count: Int) {
        let bound = Self.viewportRows * 3 + 1
        let total = Self.rowHeight * Double(count)
        var widest = 0
        let micros = Self.microsPerUpdate { step in
            let top = (total - Self.viewport) * Double(step) / Double(Self.updates - 1)
            let range = Self.range(count, top: top)
            widest = max(widest, range.count)
            #expect(range.count <= bound)
            #expect(range.lowerBound >= 0 && range.upperBound <= count)
            let firstShown = Int(top / Self.rowHeight)
            #expect(range.contains(firstShown) || count == 0)
        }
        #expect(Self.range(count, top: 0, height: 0) == 0..<min(count, Self.viewportRows * 2))
        Self.line("scroll", count, "mounted_max=\(widest) bound=\(bound)", micros)
    }

    @Test(arguments: [100, 10_000])
    func aRemountConfiguresOnlyTheChangedRow(count: Int) {
        var rows = Self.rows(count)
        let range = Self.range(count, top: Self.rowHeight * Double(count / 2))
        var mounted = Self.mounted(rows, range)
        var configured = 0
        let micros = Self.microsPerUpdate { step in
            let index = range.lowerBound + step % range.count
            rows[index].title += "!"
            let plan = FixedRowWindow.remount(window: Self.window(rows, range), mounted: mounted)
            #expect(plan.configure == [index - range.lowerBound])
            #expect(plan.released.isEmpty)
            #expect(plan.placed.count == range.count)
            configured += plan.configure.count
            mounted[rows[index].key] = rows[index]
        }
        #expect(configured == Self.updates)
        Self.line("change", count, "window=\(range.count) configured_per_update=\(configured / Self.updates)", micros)
    }

    @Test(arguments: [100, 10_000])
    func anUnchangedRemountConfiguresNone(count: Int) {
        let rows = Self.rows(count)
        let range = Self.range(count, top: Self.rowHeight * Double(count / 2))
        let mounted = Self.mounted(rows, range)
        var configured = 0
        let micros = Self.microsPerUpdate { _ in
            let plan = FixedRowWindow.remount(window: Self.window(rows, range), mounted: mounted)
            configured += plan.configure.count + plan.released.count
        }
        #expect(configured == 0)
        Self.line("same", count, "window=\(range.count) configured_per_update=0", micros)
    }

    @Test(arguments: [100, 10_000])
    func anInsertAtTheTopConfiguresTheNewRowOnly(count: Int) {
        var rows = Self.rows(count)
        var mounted = Self.mounted(rows, Self.range(rows.count, top: 0))
        var configured = 0, released = 0
        let micros = Self.microsPerUpdate { step in
            rows.insert(Row(key: "new\(step)", title: "new"), at: 0)
            let range = Self.range(rows.count, top: 0)
            let plan = FixedRowWindow.remount(window: Self.window(rows, range), mounted: mounted)
            #expect(plan.configure == [0])
            #expect(plan.released.count == 1)
            configured += plan.configure.count
            released += plan.released.count
            mounted = Self.mounted(rows, range)
        }
        #expect(configured == Self.updates)
        Self.line("insert-top", count, "configured_per_update=\(configured / Self.updates) released_per_update=\(released / Self.updates)", micros)
    }

    @Test func aRepeatedKeyGetsOneRow() {
        let rows = [Row(key: "a", title: "1"), Row(key: "b", title: "2"), Row(key: "a", title: "3")]
        let plan = FixedRowWindow.remount(window: Self.window(rows, 0..<3), mounted: ["a": rows[0], "gone": rows[1]])
        #expect(plan.placed == [0, 1])
        #expect(plan.configure == [1])
        #expect(plan.released == ["gone"])
    }
}
