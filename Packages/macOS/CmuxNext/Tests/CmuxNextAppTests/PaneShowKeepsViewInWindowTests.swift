import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A pane that is in no window yet and shows a view that is in a window takes the view when it
/// enters the window, so the view never leaves the window. Cmd-N builds its new workspace's panes
/// outside the window and the daemon's pane outside it too, and both took the New Tab page out of
/// the window; a Chromium page's view out of its window orders its page window out, and AppKit
/// waited for the window server (`-[NSWindow _doOrderWindow:]`): 88-110 ms per Cmd-N on
/// cmux8s-Mac-mini (instant-new-surfaces bench with --hang-stacks, 2026-10-24).
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneShowKeepsViewInWindowTests {
    /// Counts each time it leaves its window.
    final class TabView: NSView {
        private(set) var windowExits = 0
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, window != nil { windowExits += 1 }
        }
    }

    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        /// Where the view shows before (a parked spare, the pane that the new one replaces).
        let parking = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tab = TabView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("page"), title: "New Tab")]),
                                   reveal: LaunchReveal(deadline: .zero))

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.addSubview(parking)
            parking.addSubview(tab)
            pane.frame = root.bounds
        }
    }

    @Test func aPaneOutsideTheWindowTakesTheViewWhenItEntersTheWindow() {
        let harness = Harness()
        defer { harness.window.close() }
        harness.pane.show(harness.tab)
        #expect(harness.tab.superview === harness.parking, "the pane took the view out of the window before it entered one")
        #expect(harness.tab.windowExits == 0)

        harness.root.addSubview(harness.pane)

        #expect(harness.tab.superview === harness.pane.contentHost)
        #expect(harness.pane.hostsContent)
        #expect(harness.tab.windowExits == 0, "the view left the window \(harness.tab.windowExits) time(s)")
    }

    @Test func aViewTakenElsewhereMeanwhileStaysThere() {
        let harness = Harness()
        defer { harness.window.close() }
        harness.pane.show(harness.tab)
        let other = NSView(frame: harness.root.bounds)
        harness.root.addSubview(other)
        other.addSubview(harness.tab)

        harness.root.addSubview(harness.pane)

        #expect(harness.tab.superview === other, "the pane took back a view another place took meanwhile")
        #expect(!harness.pane.hostsContent)
    }

    @Test func aPaneInTheWindowTakesTheViewAtOnce() {
        let harness = Harness()
        defer { harness.window.close() }
        harness.root.addSubview(harness.pane)
        harness.pane.show(harness.tab)
        #expect(harness.tab.superview === harness.pane.contentHost)
        #expect(harness.tab.windowExits == 0)
    }
}
