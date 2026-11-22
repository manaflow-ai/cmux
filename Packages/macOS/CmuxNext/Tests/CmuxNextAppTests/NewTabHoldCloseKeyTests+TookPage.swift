import AppKit
import CmuxNextFocusUI
import Testing

/// A view that takes the keyboard: it stands for what had it at the New Tab key.
private final class KeyboardView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

extension NewTabHoldCloseKeyTests {
    /// The new tab took a page view that was there before the key (`NewTabHoldKeyboard.newTabTook(_:)`). The
    /// hold forgets what had the keyboard at the key only when that is in the page view that the new tab took: the
    /// person left nothing then, and a key for it is not dropped. What had the keyboard in another view stays the
    /// owner. So does the hold's own window (no view had the keyboard at the key): it is no page window, and the
    /// lookup of the view that a page window draws is not asked for it.
    /// A page window (a child window of the hold's window that is the key window at the key): the hold asks one time,
    /// at the key, which view shows its page, and forgets the window only when the new tab took that same view. The
    /// lookup's answer after the key is not asked: it gives another view then, as a place gives when 2 page views are
    /// at it.
    /// (A test of the rule's own type, with the key window as a parameter: a row can not make a child window key with
    /// certainty. The lookup of the app has its rows in `AgentPaneUnderAPageWindowTests`; no row has a page in Chromium
    /// in a hold.)
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
        took.newTabTook(page)
        took.endedUnready = true
        #expect(!took.drops(keyFor: window.firstResponder), "a key for the page view that the new tab took was dropped")

        let elsewhere = NewTabHoldKeyboard(in: window)
        elsewhere.newTabTook(other)
        elsewhere.endedUnready = true
        #expect(elsewhere.drops(keyFor: window.firstResponder), "the new tab took another page view, and a key for what had the keyboard at the key was not dropped")

        try #require(window.makeFirstResponder(nil) && window.firstResponder === window, "the window is not its own first responder")
        var asked = 0
        let ownWindow = NewTabHoldKeyboard(in: window, keyWindow: window, drawn: { _ in asked += 1; return page })
        ownWindow.newTabTook(page)
        ownWindow.endedUnready = true
        #expect(asked == 0, "the hold asked which view its own window draws, as for a page window: \(asked) times")
        #expect(ownWindow.drops(keyFor: window.firstResponder), "the hold forgot its own window as what had the keyboard at the key")

        // A page window. `shows` is the lookup's answer: `page` at the key. After the key it moves to `other`, as the
        // place of 2 page views does after a show: a hold that asks then takes the wrong view.
        let pageWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        pageWindow.isReleasedWhenClosed = false
        window.addChildWindow(pageWindow, ordered: .above)
        defer {
            window.removeChildWindow(pageWindow)
            pageWindow.close()
        }
        try #require(pageWindow.parent === window, "the page window is no child window of the hold's window")
        var shows: NSView = page
        asked = 0
        let tookItsPage = NewTabHoldKeyboard(in: window, keyWindow: pageWindow, drawn: { _ in asked += 1; return shows })
        shows = other
        tookItsPage.newTabTook(page)
        tookItsPage.endedUnready = true
        let droppedForItsPage = tookItsPage.drops(keyFor: pageWindow)
        #expect(asked == 1, "the hold asked which view shows the page window's page \(asked) times, want 1 time, at the key")
        #expect(!droppedForItsPage, "a key for the page window was dropped, and the new tab took the view that showed its page at the key")

        shows = page
        let tookAnother = NewTabHoldKeyboard(in: window, keyWindow: pageWindow, drawn: { _ in shows })
        shows = other
        tookAnother.newTabTook(other)
        tookAnother.endedUnready = true
        let droppedForAnother = tookAnother.drops(keyFor: pageWindow)
        #expect(droppedForAnother, "the new tab took a view that did not show the page window's page at the key, and a key for that window was not dropped")

        // The view that showed the page at the key is gone before the take: the page window stays the owner, so its
        // key is dropped and goes to no other place.
        weak var probe: NSView?
        let viewGone: NewTabHoldKeyboard = autoreleasepool {
            let gone = NSView(frame: page.frame)
            probe = gone
            return NewTabHoldKeyboard(in: window, keyWindow: pageWindow, drawn: { _ in gone })
        }
        try #require(probe == nil, "setup: the view that showed the page window's page at the key is not gone")
        viewGone.newTabTook(page)
        viewGone.endedUnready = true
        let droppedWithNoView = viewGone.drops(keyFor: pageWindow)
        #expect(droppedWithNoView, "the view that showed the page window's page at the key was gone at the take, and a key for that window was not dropped")

        // No page of the window's place showed at the key (a cold page in its paint hold with no page before it): the
        // lookup answers no view. The page window stays the owner, whichever view the new tab takes.
        let noView = NewTabHoldKeyboard(in: window, keyWindow: pageWindow, drawn: { _ in nil })
        noView.newTabTook(page)
        noView.endedUnready = true
        let droppedWithNoAnswer = noView.drops(keyFor: pageWindow)
        #expect(droppedWithNoAnswer, "the lookup answered no view at the key, and a key for the page window was not dropped")
        print("NewTabHoldCloseKeyTests: a page window had the keyboard at the key: asked for its view \(asked) time at the key; "
            + "the new tab took that view: a key for the window dropped: \(droppedForItsPage); "
            + "it took another view: dropped: \(droppedForAnother); the view of the key was gone: dropped: \(droppedWithNoView); "
            + "the lookup answered no view at the key: dropped: \(droppedWithNoAnswer)")
    }
}
