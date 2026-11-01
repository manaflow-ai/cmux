import AppKit
import ObjectiveC
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// fullscreen-lag (user, 2026-10-20): in full screen AppKit makes its titlebar window
/// (`NSToolbarFullScreenWindow`) a child of the window. The overlay layer took it for a
/// Chromium page and stayed in page mode (planes in the overlay panel, divider catcher panels,
/// page syncs and order checks on every event) for as long as the window was in full screen.
@MainActor @Suite(.serialized, .closesItsWindows) struct FullScreenTitlebarPageModeTests {
    private func window() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        return window
    }

    private func child(_ type: NSWindow.Type) -> NSWindow {
        let child = type.init(contentRect: CGRect(x: 200, y: 672, width: 800, height: 28), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        return child
    }

    /// AppKit's class asks its full screen owner (`_originalWindow`) when it is ordered in; a
    /// standalone one has none. This runtime subclass answers nil there and is still an
    /// `NSToolbarFullScreenWindow` to `isKind(of:)`.
    private static func standaloneTitlebarClass() throws -> NSWindow.Type {
        let name = "CmuxTestStandaloneFullScreenTitlebar"
        if let existing = NSClassFromString(name) as? NSWindow.Type { return existing }
        let base: AnyClass = try #require(NSClassFromString("NSToolbarFullScreenWindow"))
        let cls: AnyClass = try #require(objc_allocateClassPair(base, name, 0))
        let noOwner: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        class_addMethod(cls, NSSelectorFromString("_originalWindow"), imp_implementationWithBlock(noOwner), "@@:")
        objc_registerClassPair(cls)
        return try #require(cls as? NSWindow.Type)
    }

    @Test func aRealFullScreenTitlebarIsNotAPage() throws {
        let type = try Self.standaloneTitlebarClass()
        let titlebar = type.init(contentRect: CGRect(x: 0, y: 0, width: 800, height: 28), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
        defer { titlebar.closeAfterTest() }
        // Bools only: a failing #expect describes its operands, and this class's description
        // asks for its full screen owner, which a standalone one does not have.
        let isPage = WindowOverlayHost.isPageWindow(titlebar)
        let isContent = WindowOverlayLayer.isContent(titlebar)
        #expect(!isPage, "AppKit's full screen titlebar counted as a Chromium page")
        #expect(!isContent)
    }

    @Test func theFullScreenTitlebarChildLeavesTheWindowOutOfPageMode() throws {
        let window = window()
        defer { window.close() }
        let titlebar = child(try Self.standaloneTitlebarClass())
        window.addChildWindow(titlebar, ordered: .above)
        defer { window.removeChildWindow(titlebar); titlebar.close() }
        window.overlayLayer.evaluate()
        #expect(window.overlayLayer.placement == .inWindow, "AppKit's titlebar is not a page")
        #expect(WindowOverlayLayer.contentChildWindows(of: window).isEmpty)
        #expect(window.childWindows?.contains { $0 === titlebar } == true, "the titlebar stays AppKit's child")
    }

    /// The control: a plain page window (as the Chromium fork adds) does put the window in page mode.
    @Test func aPageWindowChildStillPutsTheWindowInPageMode() {
        let window = window()
        defer { window.close() }
        let page = child(NSWindow.self)
        window.addChildWindow(page, ordered: .above)
        defer { window.removeChildWindow(page); page.close() }
        window.overlayLayer.evaluate()
        #expect(window.overlayLayer.placement == .overlayWindow)
    }
}
