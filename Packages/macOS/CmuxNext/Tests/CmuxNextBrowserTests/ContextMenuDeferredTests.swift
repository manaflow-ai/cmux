import AppKit
import Testing
@testable import CmuxNextBrowser

/// The page menu opens on a later run-loop turn: present returns at once
/// (the engine asks from inside its own work, a CEF pump pass, and a menu
/// tracking loop there would stop Chromium while the menu is open). The
/// request stays pending until the menu closes.
@MainActor
@Suite struct ContextMenuDeferredTests {
    @Test func presentReturnsBeforeTheMenuOpens() {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        var completed = false
        let request = BrowserContextMenuRequest(
            items: [BrowserContextMenuItem(id: 1, title: "Back")], target: BrowserContextMenuTarget(),
            location: CGPoint(x: 4, y: 4)
        ) { _ in completed = true }
        BrowserContextMenuBuilder.present(request, in: view)
        #expect(!completed)
        #expect(BrowserContextMenuBuilder.presentedMenu == nil)
        window.contentView = nil  // the deferred block then dismisses it (view gone)
    }
}
