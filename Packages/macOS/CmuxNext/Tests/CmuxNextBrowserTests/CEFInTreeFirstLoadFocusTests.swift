import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// In-tree pages (fork API 36): a page opened for the first time never had Chromium's focus after its first load, so
/// keys typed with no click reached nothing (other-Mac run osr-func-17, `--no-click`: 0 keydowns, document.hasFocus()
/// false, document.activeElement BODY, first responder WebContentsViewCocoa). NIGHTLY's child-window mode keeps the
/// focus (osr-func-18). The order in the app's focus log:
///
/// 1. cmux's grant runs while the omnibar has the keyboard, before the page's first navigation. Chromium's focus call
///    finds no RenderWidgetHostViewCocoa yet, and the grant leaves the keyboard on the page's WebContentsViewCocoa
///    (`CEFInTreeHosting.grantFocus`: `contentView ?? page`), which hands no key to a renderer.
/// 2. The navigation starts and makes the page's RenderWidgetHostViewCocoa. CEF asks to focus the page after it
///    (`OnSetFocus`, source navigation): cmux refused every ask made outside its own grant.
/// 3. Nothing else focuses the new view: the page has no focus until it is hidden and shown again.
///
/// The stand-in Chromium does what CEF and the fork do: an ask cmux allows runs the fork's `FocusInTreePage`
/// (`WebContents::Focus`: the page's current RenderWidgetHostViewCocoa, if it has one, becomes first responder of the
/// window it is in), and that move meets the window's in-tree gate as `ShellWindow.makeFirstResponder` judges it
/// outside any input event.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFInTreeFirstLoadFocusTests {
    /// A view that takes the keyboard, as Chromium's views, the omnibar's field and a terminal do.
    final class KeyView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The cmux window as Chromium's own focus calls meet it: on screen (a grant waits for a window that is not), and
    /// judging each keyboard move with the in-tree gate as `ShellWindow.makeFirstResponder` does outside an input event
    /// and a focus-model move (a routed move names its target, as `routeInFlight` does there).
    final class CmuxWindow: NSWindow, FocusRouting {
        var routeInFlight: FocusRoute?
        override var isVisible: Bool { true }
        override var occlusionState: NSWindow.OcclusionState { .visible }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let routeTarget = routeInFlight != nil ? responder : nil
            if InTreePageFocus.shared.refuses(responder, in: self, event: nil, focusModelApplies: false, focusedPane: { nil },
                                              paneOf: { _ in nil }, routeTarget: routeTarget) { return false }
            return super.makeFirstResponder(responder)
        }
    }

    /// The fork's side of one page: its WebContentsViewCocoa, which the fork puts in cmux's container as its bottom
    /// subview, and the main frame's RenderWidgetHostViewCocoa inside it once a navigation made one.
    final class StandInPage {
        let browser: Int32
        let contents = KeyView()
        private(set) var widget: KeyView?

        init(browser: Int32) { self.browser = browser }

        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in
                guard let container else {
                    contents.removeFromSuperview()
                    return nil
                }
                contents.frame = container.bounds
                container.addSubview(contents, positioned: .below, relativeTo: nil)
                return contents
            }, contentView: { [self] _ in widget })
        }

        /// A navigation starts (or commits in a new renderer): Chromium makes the main frame's view in its
        /// WebContentsViewCocoa.
        @discardableResult
        func navigationMakesItsView() -> KeyView {
            let view = KeyView(frame: contents.bounds)
            contents.addSubview(view)
            widget = view
            return view
        }

        /// `chrome_child_window::FocusInTreePage`: `WebContents::Focus` -> `RenderWidgetHostViewMac::Focus` ->
        /// `-makeFirstResponder:` on the view's window. Nothing while the page has no view.
        func focus() {
            guard let widget else { return }
            _ = widget.window?.makeFirstResponder(widget)
        }
    }

    /// CEF's `OnSetFocus(source)`: asks cmux at the C entry, then focuses the page (`SetFocus(true)`) when allowed.
    /// - Returns: Whether cmux allowed the ask.
    @discardableResult
    static func chromiumAsksForFocus(_ page: StandInPage, _ source: CEFFocusSource, _ runtime: CEFRuntime) -> Bool {
        let allowed = cefFocusRequestCallback(Unmanaged.passUnretained(runtime).toOpaque(), page.browser, source.rawValue) == 1
        if allowed { page.focus() }
        return allowed
    }

    /// One pane's Chromium page, in tree in `window` at `frame`: a tab whose browser Chromium made, its pane host, and
    /// the fork's stand-in page in the host's in-tree container.
    struct Pane {
        let tab: CEFTab
        let host: CEFPaneHost
        let page: StandInPage
        var container: CEFInTreePageView? { host.hostView.inTree.container }
    }

    static func pane(_ runtime: CEFRuntime, browser: Int32, in window: NSWindow, frame: NSRect) throws -> Pane {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.contentView.frame = frame
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        try #require(tab.browserID == browser)
        try #require(window.contentView).addSubview(tab.contentView)
        let page = StandInPage(browser: browser)
        #expect(host.hostView.inTree.pageWindowCreated(browser: browser, calls: page.calls))
        endTurn() // the page's in-tree request runs at the end of the turn; the view's first frame commits
        try #require(host.hostView.inTree.isInTree && page.contents.window === window,
                     "the stand-in page is not in the cmux window: the test proves nothing")
        try #require(tab.presentation == .inTree && tab.isShown && tab.canTakeKeys, "the page cannot take the keys: \(tab.focusAskState)")
        return Pane(tab: tab, host: host, page: page)
    }

    static func endTurn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// In-tree pages on, a runtime with the stand-in shim, and a cmux window with an omnibar field that has the
    /// keyboard.
    static func withCmuxWindow(_ body: (CEFRuntime, CmuxWindow, KeyView) throws -> Void) throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = CmuxWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 340), styleMask: .borderless,
                                backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let omnibar = KeyView(frame: NSRect(x: 0, y: 310, width: 800, height: 30))
        try #require(window.contentView).addSubview(omnibar)
        try body(runtime, window, omnibar)
    }

    /// The failing order: cmux grants the new page the keyboard while the omnibar has it and before the page's first
    /// navigation, the navigation makes the page's view, and CEF asks to focus the page. The ask is allowed (the page
    /// has cmux's keyboard: the window's first responder is in its container), and the page's view takes the keyboard
    /// through the window's gate. A later renderer swap keeps it: Chromium's focus restore moves it to the new view.
    @Test func aPageGrantedBeforeItsFirstNavigationGetsTheKeyboardFromChromiumsAskAfterIt() throws {
        try Self.withCmuxWindow { runtime, window, omnibar in
            let pane = try Self.pane(runtime, browser: 61, in: window, frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            FocusSpyShim.onGrant = { MainActor.assumeIsolated { _ = Self.chromiumAsksForFocus(pane.page, .system, runtime) } }
            defer { FocusSpyShim.onGrant = nil }
            try #require(window.makeFirstResponder(omnibar))

            // cmux's grant (the focus applier opened the page), before Chromium made the page's view.
            pane.tab.setFocused(true)
            try #require(FocusSpyShim.granted == [61], "cmux did not grant the page: \(pane.tab.focusAskState)")
            try #require(window.firstResponder === pane.page.contents,
                         "the grant before the first navigation did not leave the keyboard on the page's WebContentsViewCocoa: the order of the bug is not reproduced")

            // The navigation makes the page's view, and CEF asks to focus the page after it.
            let view = pane.page.navigationMakesItsView()
            #expect(Self.chromiumAsksForFocus(pane.page, .navigation, runtime),
                    "Chromium's focus ask after the first navigation was refused while the page had cmux's keyboard")
            #expect(window.firstResponder === view,
                    "the page's view never took the keyboard: keys typed with no click reach the WebContentsViewCocoa (first responder \(String(describing: window.firstResponder)))")

            // A navigation that commits in a new renderer: Chromium focuses the new view of a page that has the focus.
            let next = pane.page.navigationMakesItsView()
            #expect(Self.chromiumAsksForFocus(pane.page, .system, runtime))
            #expect(window.firstResponder === next, "Chromium's focus restore in a page that has the keyboard was refused")
        }
    }

    /// The rule's other side: while the omnibar or a terminal has the keyboard, the page's asks are refused whatever
    /// Chromium's reason, and Chromium's own focus call cannot take the keyboard: a loading page never takes the keys
    /// from where the person types.
    @Test func aPageNeverTakesTheKeyboardFromTheOmnibarOrATerminal() throws {
        try Self.withCmuxWindow { runtime, window, omnibar in
            let pane = try Self.pane(runtime, browser: 62, in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let terminal = KeyView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
            try #require(window.contentView).addSubview(terminal)
            pane.page.navigationMakesItsView()

            for holder in [omnibar, terminal] {
                try #require(window.makeFirstResponder(holder))
                #expect(!Self.chromiumAsksForFocus(pane.page, .navigation, runtime), "a navigation ask took the keys")
                #expect(!Self.chromiumAsksForFocus(pane.page, .system, runtime), "a system ask took the keys")
                pane.page.focus()
                #expect(window.firstResponder === holder, "Chromium's focus call moved the keyboard into the page")
            }
        }
    }

    /// A page that is not shown (the content lifecycle hid it) is refused, even while its view keeps the keyboard
    /// until the end of the turn; once its host hides, Chromium's focus call cannot reach its view.
    @Test func aHiddenPagesAskIsRefused() throws {
        try Self.withCmuxWindow { runtime, window, omnibar in
            let pane = try Self.pane(runtime, browser: 63, in: window, frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            try #require(window.makeFirstResponder(omnibar))
            pane.tab.setFocused(true)
            try #require(window.firstResponder === pane.page.contents)

            pane.tab.setContentVisible(false)
            let view = pane.page.navigationMakesItsView()
            #expect(!Self.chromiumAsksForFocus(pane.page, .navigation, runtime), "a hidden page's ask was allowed")
            #expect(!Self.chromiumAsksForFocus(pane.page, .system, runtime))
            Self.endTurn() // the host hides at the end of the turn
            pane.page.focus()
            #expect(window.firstResponder !== view, "a hidden page's view took the keyboard")
        }
    }

    /// Another pane's page: while the first pane's page has the keyboard, the second's asks and its view are refused.
    @Test func anotherPanesPageNeverTakesTheKeyboard() throws {
        try Self.withCmuxWindow { runtime, window, omnibar in
            let left = try Self.pane(runtime, browser: 64, in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let right = try Self.pane(runtime, browser: 65, in: window, frame: NSRect(x: 400, y: 0, width: 400, height: 300))
            try #require(window.makeFirstResponder(omnibar))
            left.tab.setFocused(true)
            let holder = try #require(window.firstResponder as? NSView)
            let leftContainer = try #require(left.container)
            try #require(holder.isDescendant(of: leftContainer), "the left page did not take the keyboard")
            let other = right.page.navigationMakesItsView()

            #expect(!Self.chromiumAsksForFocus(right.page, .navigation, runtime), "another pane's page took the keys")
            #expect(!Self.chromiumAsksForFocus(right.page, .system, runtime))
            right.page.focus()
            #expect(window.firstResponder === holder, "another pane's view took the keyboard from the page that has it")
            #expect(window.firstResponder !== other)
        }
    }
}
