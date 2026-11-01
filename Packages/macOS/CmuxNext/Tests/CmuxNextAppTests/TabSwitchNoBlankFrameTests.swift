import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo's chrome call (BACKLOG "Ideas without a PR"): a tab switch never shows a blank frame. A pane
/// switching to a tab that has not drawn yet (an agent or New Tab page before its first paint) keeps
/// the tab it showed until the new one paints, then swaps in one frame. Runs a real pane in a window.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabSwitchNoBlankFrameTests {
    /// A tab that draws nothing until it paints, as an agent page does.
    final class UnpaintedPage: NSView, PaneFirstPaintGated {
        private var painted = false
        private var waiting: [() -> Void] = []
        var awaitsFirstPaint: Bool { !painted }
        func whenFirstPainted(_ body: @escaping () -> Void) {
            if painted { body() } else { waiting.append(body) }
        }

        func paint() {
            painted = true
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    final class Pane {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]),
                                   reveal: LaunchReveal(deadline: .zero))

        init() {
            window.isReleasedWhenClosed = false
            // The tab bar above the toolbar (the default): no header band.
            pane.barOrder = .aboveToolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
        }

        func select(_ view: NSView) {
            pane.show(view)
            pane.layoutSubtreeIfNeeded()
        }

        /// The tab views the pane draws now.
        var shown: [NSView] {
            pane.contentHost.subviews.filter { !$0.isHidden && $0.alphaValue > 0 }
        }

        /// The pane draws a tab, and no tab it draws is still blank.
        var drawsATab: Bool {
            !shown.isEmpty && !shown.contains { ($0 as? PaneFirstPaintGated)?.awaitsFirstPaint == true }
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func aSwitchToATabThatHasNotDrawnKeepsTheLastTabUntilItPaints() {
        let pane = Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let page = UnpaintedPage()
        pane.select(page)
        #expect(pane.drawsATab, "the pane went blank on the switch")
        #expect(pane.shown.contains { $0 === terminal }, "the last tab left before the new one painted")
        page.paint()
        pane.pane.layoutSubtreeIfNeeded()
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(page)], "the painted tab shows alone")
    }

    @Test func rapidSwitchesThroughTabsThatHaveNotDrawnNeverGoBlank() {
        let pane = Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let first = UnpaintedPage(), second = UnpaintedPage()
        pane.select(first)
        #expect(pane.drawsATab)
        pane.select(second)
        #expect(pane.drawsATab, "a second switch before the first page painted went blank")
        #expect(pane.shown.contains { $0 === terminal })
        second.paint()
        pane.pane.layoutSubtreeIfNeeded()
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
    }

    @Test func switchingBackToTabsThatDrewShowsThemAtOnce() {
        let pane = Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let page = UnpaintedPage()
        pane.select(page)
        page.paint()
        pane.pane.layoutSubtreeIfNeeded()
        pane.select(terminal)
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(terminal)], "the terminal tab came back blank or late")
        pane.select(page)
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(page)], "a page that drew waited again")
    }
}
