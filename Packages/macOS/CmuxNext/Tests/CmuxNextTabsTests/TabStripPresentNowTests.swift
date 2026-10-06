import AppKit
import Testing
@testable import CmuxNextTabs

/// Cmd-T (Lawrence 2026-10-06, hqacp-v2 proof): the first frame after the key shows the New
/// Tab tab and its page together. A tab the window just opened is applied in that same turn
/// and shown at its full width, not grown in from zero over the next frames.
@MainActor @Suite struct TabStripPresentNowTests {
    @Test func aTabPresentedNowHasItsFullWidthAndOpacityInTheSameTurn() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("shell"), title: "zsh")], selectedID: TabID("shell"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView?.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)

        model.tabs.append(TabItem(id: TabID("page"), title: "New Tab"))
        model.selectedID = TabID("page")
        strip.presentNow()

        let cell = try #require(strip.cells[TabID("page")])
        let slot = try #require(strip.result.slot(TabID("page")))
        #expect(slot.width > 0)
        #expect(abs(cell.frame.width - slot.width) < 1, "width \(cell.frame.width) of \(slot.width): it grew in")
        #expect(cell.layer.opacity == 1, "it faded in")
        #expect(cell.isSelected)
        #expect(strip.presentedTabIDs == [TabID("shell"), TabID("page")])
    }
}
