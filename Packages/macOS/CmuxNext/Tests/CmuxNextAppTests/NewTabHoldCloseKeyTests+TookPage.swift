import AppKit
import CmuxNextFocusUI
import Testing

/// A view that takes the keyboard: it stands for what had it at the New Tab key.
private final class KeyboardView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

extension NewTabHoldCloseKeyTests {
    /// The new tab took a page view that was there before the key (`NewTabHoldKeyboard.newTabTook(_:drawn:)`). The
    /// hold forgets what had the keyboard at the key only when that is in the page view that the new tab took: the
    /// person left nothing then, and a key for it is not dropped. What had the keyboard in another view stays the
    /// owner. So does the hold's own window (no view had the keyboard at the key): it is no page window, and the
    /// lookup of the view that a page window draws is not asked for it.
    /// (A test of the rule's own type. The case of a page window, a key child window of the hold's window, has no
    /// row: a row can not make a child window key with certainty.)
    @Test func aHoldForgetsWhatHadTheKeyboardOnlyWhenTheNewTabTookItsPageView() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let page = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let other = NSView(frame: CGRect(x: 120, y: 0, width: 100, height: 100))
        content.addSubview(page)
        content.addSubview(other)
        let inPage = KeyboardView(frame: page.bounds)
        page.addSubview(inPage)
        try #require(window.makeFirstResponder(inPage) && window.firstResponder === inPage, "the view in the page view did not take the keyboard")

        let took = NewTabHoldKeyboard(in: window)
        took.newTabTook(page) { _ in nil }
        took.endedUnready = true
        #expect(!took.drops(keyFor: window.firstResponder), "a key for the page view that the new tab took was dropped")

        let elsewhere = NewTabHoldKeyboard(in: window)
        elsewhere.newTabTook(other) { _ in nil }
        elsewhere.endedUnready = true
        #expect(elsewhere.drops(keyFor: window.firstResponder), "the new tab took another page view, and a key for what had the keyboard at the key was not dropped")

        try #require(window.makeFirstResponder(nil) && window.firstResponder === window, "the window is not its own first responder")
        let ownWindow = NewTabHoldKeyboard(in: window)
        var asked = 0
        ownWindow.newTabTook(page) { _ in asked += 1; return page }
        ownWindow.endedUnready = true
        #expect(asked == 0, "the hold asked which view its own window draws, as for a page window: \(asked) times")
        #expect(ownWindow.drops(keyFor: window.firstResponder), "the hold forgot its own window as what had the keyboard at the key")
    }
}
