import AppKit
import Testing
@testable import CmuxNextTabs

/// The daemon can close tabs while the user drags one (a process exits, the
/// CLI closes it, another device). Ending the drag must not trap.
@MainActor @Suite struct TabDragRaceTests {
    private func strip(count: Int) -> (TabStripModel, TabStripView, NSWindow) {
        let tabs = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("t0"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView?.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)
        return (model, strip, window)
    }

    @Test func tabsClosedDuringADragDoNotTrapOnDrop() {
        let (model, strip, window) = strip(count: 4)
        defer { window.close() }
        strip.drag = TabStripView.Drag(id: TabID("t3"), grabOffset: 0, originalIndex: 3, currentIndex: 0, isPinned: false,
                                       lastPoint: .zero, originalGroup: nil, targetGroup: nil)
        model.tabs = [model.tabs[0], model.tabs[3]]
        strip.sync(fromModel: true)
        strip.endDrag()
        #expect(strip.drag == nil)
    }

    @Test func theDraggedTabClosedDuringTheDragEndsTheDrag() {
        let (model, strip, window) = strip(count: 3)
        defer { window.close() }
        strip.drag = TabStripView.Drag(id: TabID("t2"), grabOffset: 0, originalIndex: 2, currentIndex: 0, isPinned: false,
                                       lastPoint: .zero, originalGroup: nil, targetGroup: nil)
        model.tabs = [model.tabs[0]]
        strip.sync(fromModel: true)
        strip.endDrag()
        #expect(strip.drag == nil)
        #expect(strip.displayed.map(\.id) == [TabID("t0")])
    }
}
