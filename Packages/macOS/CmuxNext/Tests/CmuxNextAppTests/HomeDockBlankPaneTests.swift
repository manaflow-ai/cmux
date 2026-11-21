import AppKit
@testable import CmuxNextApp
import Testing

/// `app.surfaces` faulted `blank pane` for Home's pane on every check (air-blue, DEV build of
/// #44303): the pane holds the `home-dock` tab, which has no terminal surface or page window of its
/// own; its content is the dock view. Home is now judged by whether that dock view is drawn in the
/// pane's window, so a shown Home is not blank and a Home whose dock view is missing, hidden or in
/// another window still is. Every other pane keeps its checks, and each blank names its reason.
@MainActor @Suite struct HomeDockBlankPaneTests {
    /// A visible pane showing its selected tab, installed and in its window, with no terminal or page.
    func status(homeDockShown: Bool? = nil, installed: Bool = true, foreignPages: Int = 0) -> PaneSurfaceStatus {
        PaneSurfaceStatus(paneKey: "p", isVisible: true, presence: "visible", selectedTab: "t", shownTab: "t", kind: "page",
                          contentInstalled: installed, contentInWindow: true, contentSize: CGSize(width: 400, height: 300),
                          foreignPages: foreignPages, homeDockShown: homeDockShown)
    }

    @Test func aShownHomeDockIsNotBlank() {
        // The Home pane as the fault saw it: no own page window, a page window over it (the dock's).
        #expect(!status(homeDockShown: true, installed: false, foreignPages: 1).isBlank)
        #expect(status(homeDockShown: true, foreignPages: 1).blankReason == nil)
    }

    @Test func aHomeDockNotDrawnIsStillBlank() {
        let missing = status(homeDockShown: false)
        #expect(missing.isBlank)
        #expect(missing.blankReason == "home_dock_not_shown")
    }

    @Test func otherPanesKeepTheirChecksAndNameTheirReason() {
        #expect(status(installed: false).blankReason == "not_installed")
        #expect(status(foreignPages: 1).blankReason == "foreign_page")
        #expect(status().blankReason == nil)
    }

    @Test func theDockViewCountsOnlyWhenDrawnInThePanesWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let dock = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!PaneController.isDrawn(dock, in: window), "not in any window")
        window.contentView?.addSubview(dock)
        #expect(PaneController.isDrawn(dock, in: window))
        #expect(!PaneController.isDrawn(dock, in: other), "in another window")
        #expect(!PaneController.isDrawn(dock, in: nil))
        dock.isHidden = true
        #expect(!PaneController.isDrawn(dock, in: window), "hidden")
        dock.isHidden = false
        dock.frame.size = .zero
        #expect(!PaneController.isDrawn(dock, in: window), "no room")
    }
}
