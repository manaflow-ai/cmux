import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-05: "for horizontal tabs, we should have subtle border between all the tabs (and
/// also between the last tab and plus button)". With the shipped metrics every gap of the row shows
/// a hairline, the last one between the last tab and +, except beside the selected tab, whose own
/// fill already makes that edge. Hover does not hide lines. The lines sit inside the gaps, so tab
/// widths and hit targets stay the same.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabStripDividerTests {
    private func strip(tabs count: Int, selected: Int) -> (TabStripView, NSWindow) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items[selected].id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: 40)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        return (strip, window)
    }

    private func shown(_ strip: TabStripView, count: Int) -> [Bool] {
        (0..<count).map { strip.cells[TabID("t\($0)")]?.showsSeparator ?? false }
    }

    @Test(arguments: [2, 5, 12])
    func everyGapShowsALineExceptBesideTheSelectedTab(_ count: Int) {
        let (strip, window) = strip(tabs: count, selected: 0)
        defer { window.close() }
        // Line i is after tab i; the selected tab 0 hides only its own line (the one after it).
        let expected = (0..<count).map { $0 != 0 }
        #expect(shown(strip, count: count) == expected)
        #expect(strip.cells[TabID("t\(count - 1)")]?.showsSeparator == true, "no line between the last tab and +")
    }

    @Test func aSelectedTabInTheMiddleHidesTheLinesOnBothItsSides() {
        let (strip, window) = strip(tabs: 5, selected: 2)
        defer { window.close() }
        #expect(shown(strip, count: 5) == [true, false, false, true, true])
    }

    @Test func hoverKeepsTheLinesBesideTheHoveredTab() {
        let (strip, window) = strip(tabs: 5, selected: 0)
        defer { window.close() }
        strip.setHovered(TabID("t2"))
        #expect(shown(strip, count: 5) == [false, true, true, true, true])
        strip.setHovered(nil)
        #expect(shown(strip, count: 5) == [false, true, true, true, true])
    }

    /// The lines are hairlines inside the gaps: they never overlap a tab's pill or the + button.
    @Test func linesSitInTheGapsAndTheLastOneBeforePlus() throws {
        let count = 4
        let (strip, window) = strip(tabs: count, selected: 0)
        defer { window.close() }
        let content = try #require(strip.contentView.layer)
        let pills = try (0..<count).map { index in
            let cell = try #require(strip.cells[TabID("t\(index)")])
            return cell.layer.convert(cell.pillFrameInCell, to: content)
        }
        for index in 0..<count {
            let cell = try #require(strip.cells[TabID("t\(index)")])
            let line = cell.layer.convert(cell.separatorLayer.frame, to: content)
            #expect(line.width > 0 && line.width <= 1, "line \(index) is \(line.width) pt wide")
            #expect(line.height > 0 && line.height < pills[index].height)
            #expect(line.minX >= pills[index].maxX, "line \(index) overlaps its tab")
            if index + 1 < count {
                #expect(line.maxX <= pills[index + 1].minX, "line \(index) overlaps the next tab")
            } else {
                #expect(!strip.newTabButton.isHidden)
                #expect(line.maxX <= strip.newTabButton.frame.minX, "the last line overlaps +")
            }
        }
    }
}
