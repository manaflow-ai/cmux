import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// pane-tab-switch-fast (u2327 "switching tabs in a pane is still very laggy"): a pane kept at most 8
/// hidden views (`parkLimit`). Cycling through more tabs than that (Ctrl-Tab, Cmd-Shift-] over 10 or 30
/// tabs) visits each tab after 8 others, so every switch found its view evicted: it left the window and
/// came back, the 30-215 ms window move parking exists to avoid. A warm switch must move no view in or
/// out of the window, whatever the number of tabs in the pane.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneParkScalingTests {
    /// Counts the content's window moves (each one is a re-attach a warm switch must avoid).
    final class WindowMoves: NSView {
        var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    @Test(arguments: [2, 10, 30])
    func aWarmSwitchMovesNoViewWhateverTheTabCount(tabs count: Int) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        let probes = (0..<count).map { _ in WindowMoves() }
        let pages = probes.enumerated().map { index, probe in
            InternalPageView(key: "local-page:markdown:\(index)", page: InternalPageID(rawValue: "markdown"), content: probe)
        }
        // First visits: each page enters the window once (a cold tab).
        for page in pages {
            pane.show(page)
            pane.layoutSubtreeIfNeeded()
        }
        let entered = probes.map(\.moves)

        // Warm: three full cycles forward (held Ctrl-Tab) and one backward.
        for _ in 0..<3 {
            for page in pages {
                pane.show(page)
                pane.layoutSubtreeIfNeeded()
                #expect(page.window === window && !page.isHidden)
            }
        }
        for page in pages.reversed() {
            pane.show(page)
            pane.layoutSubtreeIfNeeded()
        }
        let moved = zip(probes.map(\.moves), entered).reduce(0) { $0 + ($1.0 - $1.1) }
        #expect(moved == 0, "\(moved) window moves in warm switches over \(count) tabs")
        #expect(pane.parked.count == count - 1, "every tab not shown stays parked")
        #expect(pages.allSatisfy { $0.window === window })
    }
}
