import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Vertical tabs in a pane (user 2026-10-27 prototype, `tabs.barPosition` left or right): the pane
/// shows its tabs as a column on that edge, the content takes the rest of the width at full height,
/// the horizontal strip hides, and a click on a row selects that tab through the model. Top (the
/// default) and bottom keep the horizontal strip exactly as before. Rects are in pane coordinates
/// (flipped, y down).
@MainActor @Suite(.serialized) struct PaneVerticalTabsTests {
    struct Pane {
        let window: NSWindow
        let pane: PaneContentView
        let model: TabStripModel
        let content = NSView()

        init(_ position: TabBarPosition) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            model = TabStripModel(tabs: [TabItem(id: TabID("a"), title: "Alpha"), TabItem(id: TabID("b"), title: "Beta"),
                                         TabItem(id: TabID("c"), title: "Gamma")],
                                  selectedID: TabID("a"))
            pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
            pane.barPosition = position
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            pane.show(content)
            pane.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func leftPutsATabColumnOnTheLeftEdge() throws {
        let tab = Pane(.left)
        defer { tab.tearDown() }
        let column = try #require(tab.pane.verticalTabs)
        #expect(!column.isHidden)
        #expect(tab.pane.stripView.isHidden, "the horizontal strip hides")
        #expect(column.frame.minX == 0 && column.frame.width > 0)
        #expect(column.frame.minY == 0 && column.frame.height == tab.pane.bounds.height)
        #expect(tab.pane.contentHost.frame.minX == column.frame.maxX)
        #expect(tab.pane.contentHost.frame.maxX == tab.pane.bounds.maxX)
        #expect(tab.pane.contentHost.frame.height == tab.pane.bounds.height, "the content has the full height")
        #expect(tab.pane.paneHeaderHeight == 0 && tab.pane.paneFooterHeight == 0)
    }

    @Test func rightPutsATabColumnOnTheRightEdge() throws {
        let tab = Pane(.right)
        defer { tab.tearDown() }
        let column = try #require(tab.pane.verticalTabs)
        #expect(!column.isHidden)
        #expect(column.frame.maxX == tab.pane.bounds.maxX && column.frame.width > 0)
        #expect(tab.pane.contentHost.frame.minX == 0)
        #expect(tab.pane.contentHost.frame.maxX == column.frame.minX)
    }

    @Test func theColumnListsEveryTabInOrderAndMarksTheSelectedOne() throws {
        let tab = Pane(.left)
        defer { tab.tearDown() }
        let column = try #require(tab.pane.verticalTabs)
        #expect(column.rowIDs == [TabID("a"), TabID("b"), TabID("c")])
        #expect(column.selectedRowID == TabID("a"))
        tab.model.selectedID = TabID("c")
        column.syncFromModel()
        #expect(column.selectedRowID == TabID("c"))
    }

    @Test func aClickOnARowSelectsItsTab() throws {
        let tab = Pane(.right)
        defer { tab.tearDown() }
        var sent: [TabStripIntent] = []
        tab.model.intentHandler = { sent.append($0) }
        let column = try #require(tab.pane.verticalTabs)
        column.activateRow(TabID("b"))
        #expect(sent == [.select(TabID("b"))])
    }

    @Test(arguments: [TabBarPosition.top, .bottom])
    func topAndBottomKeepTheHorizontalStrip(position: TabBarPosition) {
        let tab = Pane(position)
        defer { tab.tearDown() }
        #expect(tab.pane.verticalTabs?.isHidden ?? true)
        #expect(!tab.pane.stripView.isHidden)
        #expect(tab.pane.stripView.frame.width == tab.pane.bounds.width - (tab.pane.toolbar?.view.frame.width ?? 0))
        #expect(tab.pane.contentHost.frame.width == tab.pane.bounds.width)
    }

    @Test func switchingBackToTopRestoresTheStrip() throws {
        let tab = Pane(.left)
        defer { tab.tearDown() }
        tab.pane.barPosition = .top
        tab.pane.layoutSubtreeIfNeeded()
        #expect(tab.pane.verticalTabs?.isHidden ?? true)
        #expect(!tab.pane.stripView.isHidden)
        #expect(tab.pane.contentHost.frame.minX == 0 && tab.pane.contentHost.frame.width == tab.pane.bounds.width)
        #expect(tab.pane.contentHost.frame.minY == tab.pane.stripHeight)
    }
}
