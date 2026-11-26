import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// Off-screen pages (approach 5): the select check passed or failed across runs of one build (other-Mac runs osr-func-3
/// to osr-func-6). In the failing order the page opened, cmux granted it the keyboard (the page view became the cmux
/// window's first responder, SetFocus(true)), then the page's navigation replaced Chromium's view of it. Chromium keeps
/// a focused page focused across that swap by focusing the new view (the windowless view's `Focus()`), and the windowless
/// view asks the client first: `CefFocusHandler::OnSetFocus` (source system). cmux refused every such ask made outside
/// its own grant, so the page lost Chromium's focus while its view stayed the first responder; a later press in it does
/// not grant again (the view has the keyboard already), document.hasFocus() stayed false and the select popup never
/// opened. The rule in-tree pages follow: the page has Chromium's focus whenever cmux's first responder is its view.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFOffscreenFocusRestoreTests {
    /// The C entry CEF's OnSetFocus calls (1: the page may take focus), with the runtime's context.
    func chromiumAsksForFocus(_ browser: Int32, _ source: CEFFocusSource) -> Int32 {
        cefFocusRequestCallback(Unmanaged.passUnretained(CEFRuntime.shared).toOpaque(), browser, source.rawValue)
    }

    /// A pane's off-screen page, registered with the runtime as a pane's page is, in a borderless window off screen
    /// that is never key (the bench app is never active), and a field beside it that can take the keyboard.
    func makePage(_ browser: Int32) -> (page: CEFOffscreenPageView, field: NSTextField, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = CEFOffscreenPageView(browser: browser, calls: CEFOffscreenHiddenPageTests.Shim.calls)
        let field = NSTextField(frame: NSRect(x: 0, y: 270, width: 400, height: 30))
        window.contentView?.addSubview(page)
        window.contentView?.addSubview(field)
        page.frame = NSRect(x: 0, y: 0, width: 400, height: 270)
        CEFRuntime.shared.offscreenPages.register(page)
        return (page, field, window)
    }

    /// The failing order: the page opens and cmux gives it the keyboard, its navigation replaces Chromium's view, and
    /// Chromium asks to keep the page focused (no grant running, the app not active). The ask is allowed while the page
    /// view is the window's first responder, so the select clicked next opens in a focused page.
    @Test func chromiumsFocusRestoreAfterANavigationIsAllowedWhileThePageHasTheKeyboard() {
        let (page, _, window) = makePage(9_101)
        defer { page.close(); window.closeAfterTest() }
        #expect(window.makeFirstResponder(page), "cmux's grant: the page view takes the window's keyboard")
        #expect(!window.isKeyWindow, "no activation: the window is never key")

        // The navigation committed in a new renderer; Chromium restores the focus the old view had.
        #expect(chromiumAsksForFocus(9_101, .system) == 1, "Chromium's restore of a page that has the keyboard")
        // CEF also focuses a page after a load it starts (LoadURL): harmless while the page has the keyboard.
        #expect(chromiumAsksForFocus(9_101, .navigation) == 1)
    }

    /// The rule's other side, unchanged: a page whose view does not have the keyboard (the person types in a field of
    /// the window) is refused, whatever Chromium's reason, so a page never takes the keys from where the person is.
    @Test func chromiumsAskForAPageWithoutTheKeyboardIsRefused() {
        let (page, field, window) = makePage(9_102)
        defer { page.close(); window.closeAfterTest() }
        #expect(window.makeFirstResponder(page))
        #expect(window.makeFirstResponder(field), "the keyboard moved on to a field of the window")

        #expect(chromiumAsksForFocus(9_102, .system) == 0)
        #expect(chromiumAsksForFocus(9_102, .navigation) == 0)
    }

    /// A hidden page (another tab of the pane is shown) is refused even if its view kept the window's keyboard.
    @Test func chromiumsAskForAHiddenPageIsRefused() {
        let (page, _, window) = makePage(9_103)
        defer { page.close(); window.closeAfterTest() }
        #expect(window.makeFirstResponder(page))
        page.isHidden = true

        #expect(chromiumAsksForFocus(9_103, .system) == 0)
    }
}
