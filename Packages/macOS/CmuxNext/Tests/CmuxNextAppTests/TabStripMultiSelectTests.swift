import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The strip side of Chrome's tab multi-selection (Leo 2026-10-19): Cmd-click and Shift-click on
/// a tab select several, the selected tabs that are not active draw a lighter fill, a right-click
/// hands the App the whole selection, a plain click goes back to one tab, and dragging one
/// selected tab drops them all together at its place.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripMultiSelectTests {
    @MainActor final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []

        init(tabs: Int = 6) {
            model = TabStripModel(tabs: (0..<tabs).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t1"))
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            // The App selects what the strip asks for.
            model.intentHandler = { [unowned self] intent in
                self.intents.append(intent)
                if case .select(let id) = intent { self.model.selectedID = id }
            }
        }

        /// A point inside tab `id`, in window coordinates; `dx` from its leading edge.
        func point(_ id: String, dx: CGFloat = 12) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)], "no cell for \(id)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + dx, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ id: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            let at = try point(id)
            strip.mouseDown(with: try event(.leftMouseDown, at: at, modifiers))
            strip.mouseUp(with: try event(.leftMouseUp, at: at, modifiers))
            strip.syncFromModel()
        }

        func multiSelected() -> [String] {
            model.orderedTabs.map(\.id).filter { strip.cells[$0]?.isMultiSelected == true }.map(\.rawValue)
        }
    }

    @Test func cmdClickSelectsASecondTabAndBothDrawTheSelection() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        try harness.click("t3", .command)
        #expect(harness.model.selectedID == TabID("t3"))
        #expect(harness.model.selectedTabIDs == [TabID("t1"), TabID("t3")])
        #expect(harness.multiSelected() == ["t1", "t3"], "the cells do not show the selection")
        #expect(harness.strip.cells[TabID("t3")]?.isSelected == true, "the clicked tab is the active one")
    }

    @Test func shiftClickSelectsTheRangeAndAPlainClickEndsIt() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        try harness.click("t4", .shift)
        #expect(harness.model.selectedTabIDs.map(\.rawValue) == ["t1", "t2", "t3", "t4"])
        #expect(harness.multiSelected() == ["t1", "t2", "t3", "t4"])
        // A plain click on a selected tab keeps the selection for a drag until the release.
        let at = try harness.point("t2")
        harness.strip.mouseDown(with: try harness.event(.leftMouseDown, at: at))
        #expect(harness.model.multiSelection.isMultiple, "the press ended the selection before a drag could take it")
        harness.strip.mouseUp(with: try harness.event(.leftMouseUp, at: at))
        harness.strip.syncFromModel()
        #expect(harness.model.selectedID == TabID("t2"))
        #expect(!harness.model.multiSelection.isMultiple)
        #expect(harness.multiSelected().isEmpty)
    }

    @Test func aRightClickHandsTheAppTheSelectionClickedTabFirst() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        try harness.click("t3", .command)
        var targets: [TabContextTarget] = []
        harness.strip.contextMenuProvider = { targets.append($0); return nil }
        _ = harness.strip.menu(for: try harness.event(.rightMouseDown, at: try harness.point("t1")))
        _ = harness.strip.menu(for: try harness.event(.rightMouseDown, at: try harness.point("t5")))
        #expect(targets == [.tab(TabID("t1"), selection: [TabID("t1"), TabID("t3")]), .tab(TabID("t5"), selection: [TabID("t5")])])
    }

    @Test func draggingASelectedTabDropsTheWholeSelectionInOrder() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        try harness.click("t3", .command)
        // Press t1, drag it past the last tab, release.
        let start = try harness.point("t1")
        let end = try harness.point("t5", dx: 80)
        harness.strip.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        for step in 1...6 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 6
            harness.strip.mouseDragged(with: try harness.event(.leftMouseDragged, at: CGPoint(x: x, y: start.y)))
        }
        #expect(harness.strip.dragCompanions == [TabID("t3")], "the other selected tab does not go with the drag")
        harness.strip.mouseUp(with: try harness.event(.leftMouseUp, at: CGPoint(x: end.x, y: start.y)))
        let reorders = harness.intents.compactMap { intent -> [TabID]? in if case .reorderTabs(let order) = intent { order } else { nil } }
        #expect(reorders == [["t0", "t2", "t4", "t5", "t1", "t3"].map { TabID($0) }])
        #expect(harness.model.multiSelection.isMultiple, "a drag keeps the selection")
        #expect(harness.strip.presentedTabIDs.map(\.rawValue) == ["t0", "t2", "t4", "t5", "t1", "t3"], "the strip does not show the drop")
    }

    @Test func escapeDuringAMultiTabDragLeavesTheTabsWhereTheyWere() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        try harness.click("t3", .command)
        let start = try harness.point("t1")
        harness.strip.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        harness.strip.mouseDragged(with: try harness.event(.leftMouseDragged, at: CGPoint(x: start.x + 300, y: start.y)))
        harness.strip.cancelDrag()
        #expect(harness.strip.dragCompanions.isEmpty)
        #expect(!harness.intents.contains { if case .reorderTabs = $0 { true } else { false } })
        #expect(harness.strip.presentedTabIDs.map(\.rawValue) == ["t0", "t1", "t2", "t3", "t4", "t5"])
    }
}
