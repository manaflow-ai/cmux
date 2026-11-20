import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus". After Cmd-N the new New Tab page in
/// Chromium reported its field ready while its window was not key yet: the cmux window was key with no responder of its
/// own (or the hidden old page's window was), and keys typed then reached no view ("hello world 123" left "llo world
/// 123" on the cmux23 bench). ``PageChromiumPage/dropsKeys(typedIn:appIsActive:)`` names that state, so the key router
/// queues those keys for the page instead. Each case here is a key-down's window and the page's keys.
@MainActor @Suite(.closesItsWindows)
struct PageChromiumDropsKeysTests {
    private final class Field: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aKeyInTheCmuxWindowWithNoResponderIsDroppedUntilThePageHasTheKeys() {
        let shell = Self.window(), page = FakeChromiumPage()
        defer { shell.close() }
        shell.contentView?.addSubview(page.contentView)
        shell.makeFirstResponder(nil)
        #expect(page.dropsKeys(typedIn: shell, appIsActive: true), "a key the cmux window sends to no view was not named")
        page.hasKeys = true
        #expect(!page.dropsKeys(typedIn: shell, appIsActive: true), "the page has the keys: its keys reach it")
    }

    @Test func aKeyForAViewOfItsOwnOrAnotherWindowOrAnInactiveAppIsNotDropped() {
        let shell = Self.window(), other = Self.window(), panel = Self.window(), page = FakeChromiumPage()
        defer { shell.close(); other.close(); panel.close() }
        shell.contentView?.addSubview(page.contentView)
        // An app that is not active has no key window.
        shell.makeFirstResponder(nil)
        #expect(!page.dropsKeys(typedIn: shell, appIsActive: false))
        // A view of the cmux window has the keyboard (a native field): the key is its own.
        let field = Field()
        shell.contentView?.addSubview(field)
        shell.makeFirstResponder(field)
        #expect(!page.dropsKeys(typedIn: shell, appIsActive: true), "a native field's key was taken from it")
        // Another app window, and a child window of the cmux window that is no Chromium page (a panel), keep their keys.
        #expect(!page.dropsKeys(typedIn: other, appIsActive: true), "another window's key was taken from it")
        shell.addChildWindow(panel, ordered: .above)
        #expect(!page.dropsKeys(typedIn: panel, appIsActive: true), "a child panel's key was taken from it")
    }
}
