import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A new window has no title strip (user, 2026-11-04: "we have a header now; we should not have a
/// header"). With the default `window.titlebar` the workspace-name strip is hidden and has no
/// height, and the content column reaches the window's top edge under the transparent titlebar,
/// where the traffic lights sit on the sidebar's header row. Rects are in window coordinates (y up).
@MainActor @Suite(.closesItsWindows, .serialized) struct DefaultWindowNoTitleStripTests {
    @Test func theDefaultWindowHasNoTitleStrip() throws {
        let design = DesignSettings.shared
        let before = (design.titlebar, design.tabBarPosition)
        design.titlebar = DesignSettings().titlebar
        design.tabBarPosition = .top
        defer { (design.titlebar, design.tabBarPosition) = before }
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        defer { window.close() }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()

        #expect(root.titlebar.isHidden, "no title strip with the workspace name")
        #expect(root.titlebar.frame.height == 0, "the title strip takes no height")
        let card = root.contentHost.convert(root.contentHost.bounds, to: nil)
        let windowTop = window.contentView!.bounds.maxY
        let titlebarHeight = windowTop - window.contentLayoutRect.maxY
        #expect(windowTop - card.maxY < titlebarHeight,
                "the content starts \(windowTop - card.maxY) pt below the window top, inside the \(titlebarHeight) pt titlebar area")
    }
}
