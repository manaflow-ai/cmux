import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// tab-switch-rewrite (u2873): the strip's work budget for a tab switch, deterministic where timing on
/// shared CI hosts is not. Switching between tabs that already show, at rest, walks no row of tabs (no
/// occlusion pass, no full separator pass, no frame pass) at 2, 10 or 30 tabs: its cost is the two
/// cells whose selection changed. A change that brings back an O(tabs) pass on the switch path fails here.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabSwitchWorkBudgetTests {
    @Test(arguments: [2, 10, 30])
    func aSwitchAtRestWalksNoRow(_ count: Int) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 1800, height: 40) // 30 tabs at their narrowest width fit with the pane insets
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        CATransaction.flush()
        #expect(!strip.result.isOverflowing, "every tab shows: no switch scrolls")
        let before = strip.rowPasses
        for item in items.reversed() + items {
            model.selectedID = item.id
            strip.syncFromModel()
            #expect(strip.cells[item.id]?.isSelected == true)
        }
        #expect(strip.rowPasses == before, "\(2 * count) switches walked the row: \(before) -> \(strip.rowPasses)")
    }
}
