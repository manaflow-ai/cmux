import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07: "you have a thing that you already dragged, and yet you're playing the closed tab
/// animation. You should play no animation there." A tab that moves to another pane is not closed:
/// its source strip drops it with no close, and a pane the move empties leaves in the move's turn,
/// together with the tab showing in its new pane, not one daemon echo later after an empty pane.
@Suite(.serialized, .closesItsWindows)
@MainActor struct TabMoveDepartureTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Two panes side by side, one tab each.
    private static let sideBySide = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2))

    /// The strip animates in a window on screen: with no screen nothing runs its springs.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aTabThatMovedAwayLeavesItsStripWithNoClose() throws {
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        strip.layoutSubtreeIfNeeded()
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // A close tweens only with the structural `newTab` switch on: the case where a move used to play one.
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")

        model.departures.insert(TabID("tab1"))
        model.tabs.remove(at: 1)
        strip.sync(fromModel: true)
        #expect(!strip.dying.contains(TabID("tab1")), "the moved tab played the close")
        #expect(strip.cells[TabID("tab1")] == nil, "the moved tab stayed in its old strip")
        #expect(model.departures.isEmpty, "the departure outlived its tab")

        // A real close still closes.
        model.tabs.removeLast()
        strip.sync(fromModel: true)
        #expect(strip.dying.contains(TabID("tab2")), "a close lost its tween")
    }

    /// The right pane's only tab moves into the left pane (a drop on its strip, Move to Pane): the
    /// right pane leaves in the same turn, not after the daemon's tree.
    @Test func aPaneTheMoveEmptiesLeavesInTheMovesTurn() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.sideBySide))
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        TabMoves.move(tab, to: target.pane, index: 1, services: shown.services)
        #expect(shown.content.layoutModel.isClosing(source.layoutPaneID), "the emptied pane waited for the daemon's tree")
        #expect(shown.content.layoutModel.screens.first?.layout.contains(source.layoutPaneID) == false,
                "the emptied pane still shows")
        #expect(source.stripModel.departures.contains(StripTabID(tab.id)), "the source strip would close the moved tab")
    }

    /// A pane that keeps a tab stays; only its strip drops the moved one.
    @Test func aPaneThatKeepsATabStays() throws {
        let tree = PaneCloseControllerTests.splitTree(Self.sideBySide, tabs: [1: 1, 2: 2])
        let shown = try PaneCloseControllerTests.Shown(tree: tree)
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        TabMoves.move(tab, to: target.pane, index: 1, services: shown.services)
        #expect(!shown.content.layoutModel.isClosing(source.layoutPaneID), "a pane with a tab left closed")
        #expect(source.stripModel.departures.contains(StripTabID(tab.id)))
    }
}
