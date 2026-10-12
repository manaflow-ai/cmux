import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// WebKit asks its UI delegate to move AppKit focus out of the web view when
/// Tab or Shift+Tab passes the page's last or first control
/// (`_webView:takeFocus:`). A REPL session's keys must never move the
/// user's focus that way: in a pane next to the user's terminal, an agent's
/// Tab moved the window's first responder off the terminal.
@MainActor
@Suite("Browser REPL focus containment")
struct BrowserReplFocusContainmentTests {
    private struct Window {
        let window: NSWindow
        let before: NSTextField
        let webView: WKWebView
        let after: NSTextField
    }

    /// A window (never shown) with a field, a web view and a field in its key view loop.
    private func makeWindow() -> Window {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        let before = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let webView = WKWebView(frame: NSRect(x: 0, y: 30, width: 400, height: 300))
        let after = NSTextField(frame: NSRect(x: 0, y: 340, width: 100, height: 20))
        for view in [before, webView, after] as [NSView] { content.addSubview(view) }
        before.nextKeyView = webView
        webView.nextKeyView = after
        after.nextKeyView = before
        window.initialFirstResponder = before
        return Window(window: window, before: before, webView: webView, after: after)
    }

    private func isFirstResponder(_ view: NSView, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder === view { return true }
        // A focused text field's first responder is its field editor.
        if let editor = responder as? NSText, editor.delegate === view as AnyObject { return true }
        return false
    }

    @Test func automatedFocusNavigationOutOfThePageLeavesTheUsersFocusAlone() async {
        let setup = makeWindow()
        #expect(setup.window.makeFirstResponder(setup.before))
        #expect(isFirstResponder(setup.before, in: setup.window))
        await setup.webView.withAutomationFocusContainment {
            setup.webView.browserTakeFocus(forward: true)
            setup.webView.browserTakeFocus(forward: false)
        }
        #expect(isFirstResponder(setup.before, in: setup.window))
    }

    @Test func automatedFocusNavigationKeepsFocusInADrivenPage() async {
        let setup = makeWindow()
        #expect(setup.window.makeFirstResponder(setup.webView))
        await setup.webView.withAutomationFocusContainment {
            setup.webView.browserTakeFocus(forward: true)
        }
        #expect(setup.window.firstResponder === setup.webView)
    }

    // WebKit can handle a key after the driver's round trip (a Tab queued
    // behind Shift's flagsChanged), so the takeFocus may come after the
    // automated input ended. Seen live: Shift+Tab from a driven page moved the
    // first responder off the user's terminal. Focus that is not in the web
    // view cannot leave it, whoever asks.
    @Test func focusTheWebViewDoesNotHoldNeverMoves() {
        let setup = makeWindow()
        // The user's focus is in the view after the web view; Shift+Tab out
        // of the page would select the view before it.
        #expect(setup.window.makeFirstResponder(setup.after))
        setup.webView.browserTakeFocus(forward: false)
        #expect(isFirstResponder(setup.after, in: setup.window))
        setup.webView.browserTakeFocus(forward: true)
        #expect(isFirstResponder(setup.after, in: setup.window))
    }

    @Test func aRenderWindowNeverHandsFocusOn() {
        let panel = BrowserOffscreenRenderPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        panel.contentView = content
        let webView = WKWebView(frame: content.bounds)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        content.addSubview(webView)
        content.addSubview(other)
        webView.nextKeyView = other
        other.nextKeyView = webView
        #expect(panel.makeFirstResponder(webView))
        webView.browserTakeFocus(forward: true)
        #expect(panel.firstResponder === webView)
    }

    @Test func theUsersOwnTabLeavesThePageAsBefore() {
        let setup = makeWindow()
        #expect(setup.window.makeFirstResponder(setup.webView))
        setup.webView.browserTakeFocus(forward: true)
        #expect(isFirstResponder(setup.after, in: setup.window))
        #expect(setup.window.makeFirstResponder(setup.webView))
        setup.webView.browserTakeFocus(forward: false)
        #expect(isFirstResponder(setup.before, in: setup.window))
    }

    @Test func containmentEndsWithTheInputThatStartedIt() async throws {
        let setup = makeWindow()
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            try await setup.webView.withAutomationFocusContainment { throw Failed() }
        }
        #expect(!setup.webView.isContainingAutomationFocus)
        await setup.webView.withAutomationFocusContainment {
            #expect(setup.webView.isContainingAutomationFocus)
        }
        #expect(!setup.webView.isContainingAutomationFocus)
    }
}
