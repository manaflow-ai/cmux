import AppKit
import CmuxNextFocusUI
import ObjectiveC
import Testing

/// "when browser in cmux-next is focused, the application itself is not" (Lawrence, 2026-11-17).
///
/// A Chromium page (a browser tab, the agent chat, Home) is a child window of the cmux window that
/// takes the key while the page has the keyboard; the cmux window stays main and looks active
/// (`ChromiumPageWindowMain`). The focus model's `windowKey` is then false (focus-core W5: only the
/// window AppKit made key holds it). The notification rules (`isViewed`, `viewedTabs`) read it as
/// "the person looks at this window", so while the person typed in a page every tab of that window
/// counted as unseen: its notification rang and stayed unread and its agent's attention banner
/// showed, as if cmux were in the background. They ask ``NSWindow/holdsKeyboard(key:)`` too, which
/// counts the window's own page window as the window.
@MainActor
@Suite(.serialized)
struct WindowHoldsKeyboardTests {
    /// `CefNSWindow`, a Chromium page window's class: the app has it from the Chromium framework, a
    /// test process makes a stand-in of the same name.
    static func pageWindowClass() throws -> NSWindow.Type {
        if let existing = objc_lookUpClass("CefNSWindow") { return try #require(existing as? NSWindow.Type) }
        let made: AnyClass = try #require(objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0))
        objc_registerClassPair(made)
        return try #require(made as? NSWindow.Type)
    }

    private static func window(_ type: NSWindow.Type = NSWindow.self) -> NSWindow {
        let window = type.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                               backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The window's own page window holds the keys (a page in a split, the agent chat): the window
    /// holds the keyboard, and so it does through a page a page opened over itself (DevTools).
    @Test func thePageWindowInsideTheWindowHoldsItsKeyboard() throws {
        let pageClass = try Self.pageWindowClass()
        let window = Self.window(), page = Self.window(pageClass), devTools = Self.window(pageClass)
        window.addChildWindow(page, ordered: .above)
        page.addChildWindow(devTools, ordered: .above)
        defer { page.removeChildWindow(devTools); window.removeChildWindow(page); devTools.close(); page.close(); window.close() }
        try #require(page.parent === window && devTools.parent === page, "AppKit did not keep the child windows' parents")
        #expect(window.holdsKeyboard(key: window))
        #expect(window.holdsKeyboard(key: page), "the window lost the keyboard to its own page window")
        #expect(window.holdsKeyboard(key: devTools), "the window lost the keyboard to its page's DevTools window")
    }

    /// A panel over the window (the palette, an editor), a plain child window, another window, a page
    /// window of another window or no key window: the window does not hold the keyboard, as before.
    @Test func aPanelAnotherWindowOrNoKeyWindowDoesNotCount() throws {
        let pageClass = try Self.pageWindowClass()
        let window = Self.window(), panel = Self.window(NSPanel.self), child = Self.window()
        let other = Self.window(), othersPage = Self.window(pageClass)
        window.addChildWindow(panel, ordered: .above)
        window.addChildWindow(child, ordered: .above)
        other.addChildWindow(othersPage, ordered: .above)
        defer {
            window.removeChildWindow(panel); window.removeChildWindow(child); other.removeChildWindow(othersPage)
            for each in [panel, child, othersPage, other, window] { each.close() }
        }
        #expect(!window.holdsKeyboard(key: nil))
        #expect(!window.holdsKeyboard(key: panel), "a panel over the window counted as the window")
        #expect(!window.holdsKeyboard(key: child), "a plain child window counted as the window")
        #expect(!window.holdsKeyboard(key: other))
        #expect(!window.holdsKeyboard(key: othersPage), "another window's page counted as this window")
    }
}
