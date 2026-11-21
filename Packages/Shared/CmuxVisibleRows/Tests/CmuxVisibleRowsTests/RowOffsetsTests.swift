import CmuxVisibleRows
import Foundation
import Testing

/// `RowOffsets` and `RowIDDiff` as Screen Sharing's Your Devices uses them (macOS `MacScreenDeviceRows`): rows of
/// 44 pt with a 1 pt hairline, a 640 pt viewport and one viewport of overscan each side. The mount range stays one
/// viewport and its overscan at 10,000 rows as at 100, and one device's change drops only that row. Each case prints one
/// `row-offsets` line with the microseconds each walk took per update.
struct RowOffsetsTests {
    static let rowHeight = 45.0
    static let viewport = 640.0

    struct Device: Equatable { var id: String, name: String }

    static func devices(_ count: Int, renamed: Int? = nil) -> [Device] {
        (0..<count).map { Device(id: "mac-\($0)", name: $0 == renamed ? "Mac \($0) renamed" : "Mac \($0)") }
    }

    /// The median of `runs` timings of `body`, in microseconds.
    static func micros(runs: Int = 21, _ body: () -> Void) -> Double {
        var times: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            let took = ContinuousClock.now - start
            times.append(Double(took.components.seconds) * 1e6 + Double(took.components.attoseconds) / 1e12)
        }
        return times.sorted()[runs / 2]
    }

    @Test(arguments: [100, 10_000])
    func mountRangeStaysOneViewportAndItsOverscan(count: Int) {
        let offsets = RowOffsets(count: count) { _ in Self.rowHeight }
        #expect(offsets.height == Double(count) * Self.rowHeight)
        let bound = 3 * Int((Self.viewport / Self.rowHeight).rounded(.up)) + 2
        let midY = min(offsets.height / 2, 2_000)
        let range = offsets.rows(reaching: midY - Self.viewport, midY + 2 * Self.viewport)
        #expect(range.count <= bound)
        #expect(offsets.top(range.lowerBound) <= midY - Self.viewport + Self.rowHeight)
        // One row of scroll brings in at most two rows (the row, and one cut by the edge).
        let next = offsets.rows(reaching: midY - Self.viewport + Self.rowHeight, midY + 2 * Self.viewport + Self.rowHeight)
        #expect(next.upperBound - range.upperBound <= 2)
        let end = offsets.rows(reaching: offsets.height - Self.viewport, offsets.height + Self.viewport)
        #expect(end.upperBound == count)
        #expect(offsets.rows(reaching: offsets.height + 1, offsets.height + 100).isEmpty)

        let build = Self.micros { _ = RowOffsets(count: count) { _ in Self.rowHeight } }
        let lookup = Self.micros { _ = offsets.rows(reaching: midY - Self.viewport, midY + 2 * Self.viewport) }
        print("row-offsets mac-screen-devices n=\(count) mounted=\(range.count) bound=\(bound) "
            + "offsetsBuildMicros=\(String(format: "%.1f", build)) rangeLookupMicros=\(String(format: "%.2f", lookup))")
    }

    @Test(arguments: [100, 10_000])
    func oneDeviceChangeDropsOnlyThatRow(count: Int) {
        let before = Self.devices(count)
        let offsets = RowOffsets(count: count) { _ in Self.rowHeight }
        let range = offsets.rows(reaching: 0, 3 * Self.viewport)
        var mounted: [String: Device] = [:]
        for index in range { mounted[before[index].id] = before[index] }
        let after = Self.devices(count, renamed: 2)
        var index: [String: Int] = [:]
        let indexMicros = Self.micros {
            index = Dictionary(after.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var stale: [String] = []
        let diffMicros = Self.micros { stale = RowIDDiff.stale(mounted: mounted, rows: after, index: index) }
        #expect(stale == ["mac-2"])
        // A device gone from the list is dropped too; the others stay.
        let removed = Array(after.dropFirst())
        let removedIndex = Dictionary(removed.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(RowIDDiff.stale(mounted: mounted, rows: removed, index: removedIndex)) == ["mac-0", "mac-2"])
        print("row-offsets mac-screen-devices n=\(count) mounted=\(mounted.count) stale=\(stale.count) "
            + "idIndexMicros=\(String(format: "%.1f", indexMicros)) mountedDiffMicros=\(String(format: "%.2f", diffMicros))")
    }
}
