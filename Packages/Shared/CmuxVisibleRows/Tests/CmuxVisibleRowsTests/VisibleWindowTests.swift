import CmuxVisibleRows
import Testing

/// The reveal math of the macOS tab strip and vertical tab list (`VisibleWindow`), with no UI, at 100 and 10,000 items:
/// the items a viewport and its overscan need, and what a one-item scroll makes and drops, stay the viewport's,
/// whatever the length (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?").
@Suite struct VisibleWindowTests {
    /// Tabs 180 pt wide in a 1400 pt strip; rows 30 pt tall (28 and 2 of spacing) from 6 pt down in a 600 pt list.
    static let tab = 180.0, strip = 1400.0
    static let row = 28.0, spacing = 2.0, top = 6.0, list = 600.0

    static func tabStart(_ i: Int) -> Double { Double(i) * tab }
    static func tabEnd(_ i: Int) -> Double { Double(i + 1) * tab }
    static func rowStart(_ i: Int) -> Double { top + Double(i) * (row + spacing) }
    static func rowEnd(_ i: Int) -> Double { rowStart(i) + row }

    @Test(arguments: [100, 10_000])
    func aStripViewportNeedsItsTabsAndOneViewportEachSide(_ count: Int) {
        let content = Double(count) * Self.tab
        let offset = max(0, (content - Self.strip) / 2)
        let mounted = VisibleWindow.mounted(count: count, offset: offset, length: Self.strip, start: Self.tabStart, end: Self.tabEnd)
        let bound = Int((3 * Self.strip / Self.tab).rounded(.up)) + 2
        #expect(mounted.count <= bound, "\(mounted.count) tabs mounted at n=\(count), bound \(bound)")
        // Every tab in view is in it, and it is the linear scan's answer.
        let inView = VisibleWindow.range(count: count, low: offset, high: offset + Self.strip, start: Self.tabStart, end: Self.tabEnd)
        #expect(mounted.clamped(to: inView) == inView)
        let span = VisibleWindow.span(offset: offset, length: Self.strip)
        let linear = (0..<count).filter { Self.tabEnd($0) >= span.lowerBound && Self.tabStart($0) <= span.upperBound }
        #expect(Array(mounted) == linear)
    }

    @Test(arguments: [100, 10_000])
    func aOneTabScrollMakesAndDropsAboutOneTab(_ count: Int) {
        let content = Double(count) * Self.tab
        guard content > Self.strip else { return }
        let offset = (content - Self.strip) / 2
        let before = VisibleWindow.mounted(count: count, offset: offset, length: Self.strip, start: Self.tabStart, end: Self.tabEnd)
        let after = VisibleWindow.mounted(count: count, offset: offset + Self.tab, length: Self.strip, start: Self.tabStart, end: Self.tabEnd)
        let (added, dropped) = VisibleWindow.change(from: before, to: after)
        #expect(Range.total(added) <= 2 && Range.total(dropped) <= 2, "one tab of scroll at n=\(count): +\(added) -\(dropped)")
        #expect(Set(before).subtracting(dropped.flatMap { $0 }).union(added.flatMap { $0 }) == Set(after))
    }

    @Test(arguments: [100, 10_000])
    func aListViewportDrawsItsRowsAndAOneRowScrollRevealsOne(_ count: Int) {
        let content = Self.rowStart(count) + Self.top
        let offset = max(0, min(2_000, (content - Self.list) / 2))
        let shown = VisibleWindow.range(count: count, low: offset, high: offset + Self.list, start: Self.rowStart, end: Self.rowEnd)
        #expect(shown.count <= Int((Self.list / (Self.row + Self.spacing)).rounded(.up)) + 1, "\(shown.count) rows in view at n=\(count)")
        let next = VisibleWindow.range(count: count, low: offset + Self.row + Self.spacing, high: offset + Self.list + Self.row + Self.spacing,
                                       start: Self.rowStart, end: Self.rowEnd)
        let (added, dropped) = VisibleWindow.change(from: shown, to: next)
        #expect(Range.total(added) <= 1 && Range.total(dropped) <= 1, "one row of scroll at n=\(count): +\(added) -\(dropped)")
    }

    @Test func partitionAndChangeEdges() {
        #expect(VisibleWindow.partition(0) { _ in true } == 0)
        #expect(VisibleWindow.partition(5) { $0 >= 3 } == 3)
        #expect(VisibleWindow.partition(5) { _ in false } == 5)
        #expect(VisibleWindow.range(count: 0, low: 0, high: 10, start: { _ in 0 }, end: { _ in 0 }) == 0..<0)
        #expect(VisibleWindow.change(from: 0..<5, to: 0..<5) == ([], []))
        let jump = VisibleWindow.change(from: 0..<5, to: 10..<15)
        #expect(jump.added == [10..<15] && jump.dropped == [0..<5])
        let grow = VisibleWindow.change(from: 3..<5, to: 0..<8)
        #expect(grow.added == [0..<3, 5..<8] && grow.dropped.isEmpty)
    }
}
