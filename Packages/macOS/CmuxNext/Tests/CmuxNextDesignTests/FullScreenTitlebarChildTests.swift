import AppKit
@testable import CmuxNextDesign
import Testing

/// fullscreen-lag (user, 2026-10-20): in full screen AppKit makes its titlebar window
/// (`NSToolbarFullScreenWindow`, a plain `NSWindow`) a child of the window. Counted as a
/// Chromium page, it kept the window in page mode for the whole of full screen (overlay
/// planes in the panel, divider catcher panels, page re-syncs and child order checks on
/// every event), and every drag, hover and switch lagged.
@MainActor @Suite struct FullScreenTitlebarChildTests {
    @Test func theFullScreenTitlebarWindowIsAppKitChromeNotAPage() throws {
        // The class still exists under this name and is an NSWindow that is not a panel,
        // so without the name check it would count as a page.
        let cls = try #require(NSClassFromString("NSToolbarFullScreenWindow"))
        #expect(cls.isSubclass(of: NSWindow.self))
        #expect(!cls.isSubclass(of: NSPanel.self))
        #expect(WindowOverlayHost.appKitChromeClassNames.contains("NSToolbarFullScreenWindow"))
    }

    @Test func plainWindowsStayPagesAndPanelsStayPanels() {
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        #expect(WindowOverlayHost.isPageWindow(page))
        #expect(!WindowOverlayHost.isAppKitChrome(page))
        #expect(!WindowOverlayHost.isPageWindow(panel))
        #expect(!WindowOverlayHost.isAppKitChrome(panel))
    }
}
