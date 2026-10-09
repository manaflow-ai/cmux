import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTabs
import Testing

/// Browser perf phase 2 (cx-asb1): a tab switch between two browser tabs of
/// one pane must not take a browser's chrome out of the window. AppKit pays
/// tens of ms for each window move of a toolbar (constraints, controls,
/// the page's child window), so the pane keeps the outgoing browser in
/// place, hidden, and shows it again without a move.
@MainActor @Suite(.serialized)
struct PaneContentParkingTests {
    /// Counts the window moves of the browser it is inside.
    final class WindowMoves: NSView {
        var left = 0
        var entered = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { left += 1 } else { entered += 1 }
        }
    }

    private func pane() -> (PaneContentView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let pane = PaneContentView(stripModel: TabStripModel())
        pane.frame = window.contentView!.bounds
        window.contentView!.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func browser() -> (BrowserChromeView, WindowMoves) {
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        let probe = WindowMoves()
        chrome.addSubview(probe)
        return (chrome, probe)
    }

    @Test func switchingBetweenTwoBrowserTabsKeepsBothInTheWindow() {
        let (pane, window) = pane()
        defer { window.close() }
        let (first, firstMoves) = browser()
        let (second, secondMoves) = browser()
        pane.show(first)
        pane.show(second)
        pane.show(first)
        pane.show(second)
        #expect(firstMoves.left == 0, "the outgoing browser stays in the window")
        #expect(secondMoves.left == 0)
        #expect(firstMoves.entered == 1, "each browser enters the window once")
        #expect(secondMoves.entered == 1)
        #expect(pane.content === second)
        #expect(first.isHiddenOrHasHiddenAncestor, "the browser that is not selected does not show")
        #expect(!second.isHiddenOrHasHiddenAncestor)
        #expect(second.frame == pane.contentHost.bounds)
    }

    @Test func theKeyboardLeavesABrowserThatIsNoLongerShown() throws {
        let (pane, window) = pane()
        defer { window.close() }
        let (first, _) = browser()
        let field = NSTextField()
        first.addSubview(field)
        pane.show(first)
        #expect(window.makeFirstResponder(field))
        let (second, _) = browser()
        pane.show(second)
        let responder = window.firstResponder as? NSView
        #expect(responder.map { !$0.isDescendant(of: first) } ?? true, "no hidden browser keeps the keyboard")
    }

    @Test func aTerminalStillLeavesThePane() {
        let (pane, window) = pane()
        defer { window.close() }
        let terminal = NSView()
        pane.show(terminal)
        let (chrome, _) = browser()
        pane.show(chrome)
        #expect(terminal.superview == nil, "only browsers stay in the pane")
    }

    @Test func aClosedTabsBrowserLeavesTheWindow() {
        let (pane, window) = pane()
        defer { window.close() }
        let (first, firstMoves) = browser()
        let (second, _) = browser()
        pane.show(first)
        pane.show(second)
        #expect(pane.parked.compactMap(\.view) == [first])
        pane.prunePark { $0 !== first }
        #expect(first.superview == nil, "a parked browser whose tab closed goes")
        #expect(firstMoves.left == 1)
        #expect(pane.parked.isEmpty)
    }

    @Test func aBrowserParkedInAnotherPaneShowsWhenMovedHere() {
        let (left, window) = pane()
        defer { window.close() }
        let right = PaneContentView(stripModel: TabStripModel())
        right.frame = window.contentView!.bounds
        window.contentView!.addSubview(right)
        let (moved, _) = browser()
        let (other, _) = browser()
        left.show(moved)
        left.show(other)
        #expect(moved.isHidden)
        right.show(moved)
        #expect(moved.superview === right.contentHost)
        #expect(!moved.isHidden, "a moved tab shows in its new pane")
        left.prunePark()
        #expect(left.parked.isEmpty, "the old pane forgets it")
    }

    @Test func theParkLimitBoundsHiddenBrowsers() {
        let (pane, window) = pane()
        defer { window.close() }
        let browsers = (0...PaneContentView.parkLimit + 1).map { _ in browser().0 }
        for chrome in browsers { pane.show(chrome) }
        #expect(pane.parked.count == PaneContentView.parkLimit)
        #expect(browsers[0].superview == nil, "the oldest leaves")
        #expect(browsers[1].superview === pane.contentHost)
    }
}
