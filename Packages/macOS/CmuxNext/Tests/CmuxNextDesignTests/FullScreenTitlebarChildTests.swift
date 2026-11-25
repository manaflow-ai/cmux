import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// fullscreen-lag (user, 2026-10-20): in full screen AppKit makes its titlebar window
/// (`NSToolbarFullScreenWindow`, a plain `NSWindow`) a child of the window. Counted as a
/// Chromium page, it kept the window in page mode for the whole of full screen (overlay
/// planes in the panel, divider catcher panels, page re-syncs and child order checks on
/// every event), and every drag, hover and switch lagged.
@MainActor @Suite(.closesItsWindows) struct FullScreenTitlebarChildTests {
    @Test func theFullScreenTitlebarWindowIsAppKitChromeNotAPage() throws {
        // The class still exists under this name and is an NSWindow that is not a panel,
        // so without the name check it would count as a page.
        let cls = try #require(NSClassFromString("NSToolbarFullScreenWindow"))
        let isWindow = cls is NSWindow.Type
        let isPanel = cls is NSPanel.Type
        #expect(isWindow)
        #expect(!isPanel)
        #expect(WindowOverlayHost.appKitChromeClassNames.contains("NSToolbarFullScreenWindow"))
        // An instance, as AppKit adds it under a full screen window: chrome, not a page,
        // and allowed as a child (it is AppKit's, not an overlay presenter's).
        let type = try #require(cls as? NSWindow.Type)
        let titlebar = type.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 28), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
        defer { titlebar.closeAfterTest() }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { parent.closeAfterTest() }
        // Bools only: a failing #expect describes its operands, and this class's description
        // asks for its full screen owner, which a standalone one does not have.
        let isChrome = WindowOverlayHost.isAppKitChrome(titlebar)
        let isPage = WindowOverlayHost.isPageWindow(titlebar)
        let allowed = ChildWindowPolicy.allows(titlebar, parent: parent)
        #expect(isChrome)
        #expect(!isPage)
        #expect(allowed)
    }

    @Test func plainWindowsStayPagesAndPanelsStayPanels() {
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        defer { page.closeAfterTest() }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        defer { panel.closeAfterTest() }
        #expect(WindowOverlayHost.isPageWindow(page))
        #expect(!WindowOverlayHost.isAppKitChrome(page))
        #expect(!WindowOverlayHost.isPageWindow(panel))
        #expect(!WindowOverlayHost.isAppKitChrome(panel))
    }
}
