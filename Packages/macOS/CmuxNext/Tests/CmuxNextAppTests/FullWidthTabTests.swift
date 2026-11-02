import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Full Width Tab (`palette.toggleFullWidthTab`, classic #7425): a pane's own mode in which its
/// tab strip shows only the selected tab, across the whole strip, instead of every tab. Selecting
/// another tab (keyboard, palette) shows that one full width; toggling again shows every tab.
/// The palette row, the tab context menu, `cmux tab toggle-full-width` and MCP `action run` all
/// run the one action.
@MainActor @Suite(.serialized, .closesItsWindows)
struct FullWidthTabTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let model: TabStripModel

        init(count: Int = 4, pinned: Int = 0, width: CGFloat = 900) {
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)", isPinned: $0 < pinned) }
            model = TabStripModel(tabs: tabs, selectedID: tabs[1].id)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            settle()
        }

        func settle() {
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            strip.applyFrames()
        }

        /// The tabs the strip shows (laid out wider than nothing).
        var shown: [TabID] { strip.result.slots.filter { !$0.isCollapsed && $0.width > 0 }.map(\.id) }
    }

    @Test func theActionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.toggleFullWidthTab") == nil)
    }

    @Test func theSelectedTabFillsTheStripAndTheOthersHide() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        #expect(harness.shown.count == 4)

        harness.model.showsSelectedFullWidth = true
        harness.settle()
        #expect(harness.shown == [TabID("tab1")])
        let slot = try #require(harness.strip.result.slot(TabID("tab1")))
        #expect(slot.width == harness.strip.result.availableWidth)
        #expect(!harness.strip.result.isOverflowing)

        // Another selection shows that tab full width.
        harness.model.selectedID = TabID("tab3")
        harness.settle()
        #expect(harness.shown == [TabID("tab3")])

        harness.model.showsSelectedFullWidth = false
        harness.settle()
        #expect(harness.shown.count == 4)
    }

    @Test func aPinnedSelectedTabFillsTheStripToo() {
        let harness = Harness(count: 3, pinned: 2)
        defer { harness.window.closeAfterTest() }
        harness.model.selectedID = TabID("tab0")
        harness.model.showsSelectedFullWidth = true
        harness.settle()
        #expect(harness.shown == [TabID("tab0")])
        #expect(harness.strip.result.slot(TabID("tab0"))?.width == harness.strip.result.availableWidth)
    }

    /// Each pane's choice outlives the pane's view and the app (kept in defaults, per pane key).
    @Test func eachPanesChoiceIsKeptPerPaneAcrossLaunches() throws {
        let suite = "cmux.next.tests.fullWidthTab.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices = PaneFullWidthTabs(defaults: defaults)
        #expect(!choices.contains("pane_a"))
        #expect(choices.toggle("pane_a"))
        #expect(choices.contains("pane_a"))
        #expect(!choices.contains("pane_b"))
        #expect(PaneFullWidthTabs(defaults: defaults).contains("pane_a"), "a relaunch keeps the choice")
        #expect(!choices.toggle("pane_a"))
        #expect(!PaneFullWidthTabs(defaults: defaults).contains("pane_a"))
    }
}
