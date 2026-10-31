import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A pane that a new screen takes over from a screen that goes moves to the new screen inside the
/// window: the new screen takes the pane's host before the old screen leaves. Before, the old screen
/// left the window first with the host in it, and the pane's tab view left the window too. A Chromium
/// page's view out of its window orders its page window out, and AppKit waits for the window server
/// in `-[NSWindow _doOrderWindow:]`: 88-110 ms per Cmd-N on cmux8s-Mac-mini (instant-new-surfaces
/// bench with --hang-stacks, 2026-10-24), where the daemon's screen replaces the New Tab page's
/// stand-in screen. This is the layout's half of that fix: the stand-in pane must also keep its id.
@MainActor
@Suite(.closesItsWindows)
struct ScreenReplaceKeepsTabViewInWindowTests {
    /// A tab's view that counts each time it leaves its window.
    final class TabView: NSView {
        var windowExits = 0
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, window != nil { windowExits += 1 }
        }
    }

    /// The pane's content holds the tab view; a second content for the same pane is a failure.
    final class Panes: LayoutPaneContentProvider {
        let tab = TabView()
        var made = 0
        func makeContentView(for pane: PaneID) -> NSView {
            made += 1
            let content = NSView()
            content.addSubview(tab)
            return content
        }
    }

    @Test func aPaneMovedToAReplacingScreenStaysInTheWindow() {
        _ = NSApplication.shared
        let panes = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "standIn", name: "s", layout: .splits(.leaf("pane")))],
                                activeScreenID: "standIn", focusedPane: "pane")
        let root = LayoutRootView(model: model, contentProvider: panes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        #expect(panes.tab.window === window, "the pane shows the tab")

        model.apply(screens: [LayoutScreen(id: "daemon", name: "s", layout: .splits(.leaf("pane")))])
        root.syncWithModel()

        #expect(panes.made == 1, "the pane's content was made again")
        #expect(panes.tab.window === window)
        #expect(panes.tab.windowExits == 0, "the tab view left the window \(panes.tab.windowExits) times while its screen was replaced")
        #expect(root.screenViews["standIn"] == nil)
        #expect(root.screenViews["daemon"] != nil)
    }
}
