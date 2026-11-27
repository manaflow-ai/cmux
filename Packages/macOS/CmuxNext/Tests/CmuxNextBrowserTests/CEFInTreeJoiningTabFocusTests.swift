import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// In-tree pages (fork API 36): a page opened as a new tab of a pane whose Chromium window is live never took the
/// keyboard after its first load, so keys typed with no click reached nothing. The pane showed a page before it: the
/// stand-in page a new browser tab shows first, or another page. Other-Mac runs flf-after-tabterm1, flf-after-tabterm2
/// and flf-after-tabchat2 on 7400b188 (`--no-click`, the page opened beside a workspace's own tab): 0 keydowns, the
/// window itself first responder. The order in the app's journal and focus log:
///
/// 1. The new tab joins the pane's window (`tab_add` with activate). CEF's OnAfterCreated runs inside that call, and
///    the tab's attach grants the ask the focus model made while it had no browser. The in-tree hosting still names
///    the page it showed until then (`CEFInTreeHosting.browser` changes only when a tab shows), so the grant's target
///    was that page's view. That view had the keyboard (or took it), the grant reported success, and the ask was
///    dropped.
/// 2. Chromium shows the new tab: the fork puts its WebContentsViewCocoa in cmux's container in place of the old one.
///    The old page's view leaves the window with the keyboard, and the window itself is first responder. The focus
///    model asks again; that grant finds the new page with no view and the old page's view out of the window.
/// 3. The navigation makes the new page's RenderWidgetHostViewCocoa. Chromium's focus restore and CEF's ask after the
///    navigation come while no view of the page has the keyboard, and are refused. Nothing grants the page again:
///    there is no kept ask.
///
/// The stand-in Chromium window does what Chromium and the fork do with a pane's tabs: each tab has its own
/// WebContentsViewCocoa (and a RenderWidgetHostViewCocoa once a navigation made one), the active tab's is cmux's
/// container's bottom subview, and a tab that joins with activate replaces it there right after its OnAfterCreated.
/// The cmux window judges each keyboard move with the in-tree gate as `ShellWindow.makeFirstResponder` does
/// (``CEFInTreeFirstLoadFocusTests/CmuxWindow``).
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFInTreeJoiningTabFocusTests {
    typealias KeyView = CEFInTreeFirstLoadFocusTests.KeyView
    typealias CmuxWindow = CEFInTreeFirstLoadFocusTests.CmuxWindow

    /// The browser of the pane's first page, and of the tab that joins its window.
    static let firstBrowser: Int32 = 81
    static let joiningBrowser: Int32 = 82
    static let address = "http://127.0.0.1:8765/osr.html?n=join"

    /// One Chromium window of a pane, as the fork shows its tabs in tree.
    final class StandInChromiumWindow {
        /// One tab's page: its WebContentsViewCocoa, and the main frame's RenderWidgetHostViewCocoa inside it once a
        /// navigation made one.
        final class Page {
            let contents = KeyView()
            var widget: KeyView?
        }

        private(set) var pages: [Int32: Page]
        private(set) var active: Int32
        private weak var container: NSView?

        init(first browser: Int32) {
            pages = [browser: Page()]
            active = browser
        }

        /// `setInTreeContainer:contents:`: the window's active tab's WebContentsViewCocoa goes into `container` (the
        /// fork follows the window's current WebContents from then on), and the call returns it.
        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in
                self.container = container
                guard let container else {
                    pages[active]?.contents.removeFromSuperview()
                    return nil
                }
                return show(active, in: container)
            }, contentView: { [self] browser in pages[browser]?.widget })
        }

        /// The fork's adopt on a WebContents attach: `browser`'s WebContentsViewCocoa replaces every other tab's in the
        /// container.
        private func show(_ browser: Int32, in container: NSView) -> NSView? {
            for (id, page) in pages where id != browser { page.contents.removeFromSuperview() }
            guard let page = pages[browser] else { return nil }
            page.contents.frame = container.bounds
            if page.contents.superview !== container { container.addSubview(page.contents, positioned: .below, relativeTo: nil) }
            return page.contents
        }

        /// `cmux_tab_add`: Chromium makes the tab's browser and CEF's OnAfterCreated runs inside the call; then, with
        /// activate, the window shows the new tab.
        func tabAdd(_ browser: Int32, activate: Bool, runtime: CEFRuntime) -> Int32 {
            pages[browser] = Page()
            runtime.handle(.afterCreated(browser: browser, request: 0, window: 1))
            if activate {
                active = browser
                if let container { _ = show(browser, in: container) }
            }
            return browser
        }

        /// A navigation starts: Chromium makes the main frame's view in the tab's WebContentsViewCocoa.
        @discardableResult
        func navigationMakesItsView(_ browser: Int32) -> KeyView? {
            guard let page = pages[browser] else { return nil }
            let view = KeyView(frame: page.contents.bounds)
            page.contents.addSubview(view)
            page.widget = view
            return view
        }

        /// `WebContents::Focus` -> `RenderWidgetHostViewMac::Focus` -> `-makeFirstResponder:` on the view's window
        /// (Chromium's focus restore after a navigation, and CEF's `SetFocus(true)`). Nothing while the tab has no view,
        /// or its view is in no window (a background tab).
        func focus(_ browser: Int32) {
            guard let widget = pages[browser]?.widget else { return }
            _ = widget.window?.makeFirstResponder(widget)
        }
    }

    /// CEF's `OnSetFocus(source)`: asks cmux at the C entry, then focuses the page when allowed.
    /// - Returns: Whether cmux allowed the ask.
    @discardableResult
    static func chromiumAsksForFocus(_ browser: Int32, _ source: CEFFocusSource, _ runtime: CEFRuntime,
                                     _ chromium: StandInChromiumWindow) -> Bool {
        let allowed = cefFocusRequestCallback(Unmanaged.passUnretained(runtime).toOpaque(), browser, source.rawValue) == 1
        if allowed { chromium.focus(browser) }
        return allowed
    }

    /// A pane whose page has the keyboard, and the tab with an address that joined its live Chromium window in that
    /// page's place.
    struct Join {
        let chromium: StandInChromiumWindow
        let host: CEFPaneHost
        let first: CEFTab
        let joining: CEFTab
        /// The first page's view, which had the keyboard.
        let firstView: KeyView
        var container: CEFInTreePageView? { host.hostView.inTree.container }
    }

    /// The pane's first page is in tree in `window` with its view and the keyboard. Then the pane shows a new tab with
    /// an address in its place (the person opened a page in this pane), the focus model asks for the new page while it
    /// has no browser, and the turn ends: the tab joins the pane's window after the frame (`createDeferred`).
    static func join(_ runtime: CEFRuntime, in window: CmuxWindow, frame: NSRect) throws -> Join {
        let chromium = StandInChromiumWindow(first: firstBrowser)
        JoiningTabShim.onTabAdd = { activate in
            MainActor.assumeIsolated { chromium.tabAdd(Self.joiningBrowser, activate: activate, runtime: runtime) }
        }
        JoiningTabShim.onGrant = { browser in
            MainActor.assumeIsolated { _ = Self.chromiumAsksForFocus(browser, .system, runtime, chromium) }
        }
        let root = try #require(window.contentView)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        first.contentView.frame = frame
        host.add(first)
        host.ensureCreated(first)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: firstBrowser, request: request, window: 1))
        try #require(first.browserID == firstBrowser)
        root.addSubview(first.contentView)
        #expect(host.hostView.inTree.pageWindowCreated(browser: firstBrowser, calls: chromium.calls))
        CEFInTreeFirstLoadFocusTests.endTurn() // the page's in-tree request runs at the end of the turn
        let firstView = try #require(chromium.navigationMakesItsView(firstBrowser))
        try #require(host.hostView.inTree.isInTree && firstView.window === window,
                     "the first page is not in tree in the cmux window: the test proves nothing")
        first.setFocused(true)
        try #require(window.firstResponder === firstView,
                     "the pane's first page did not take the keyboard: the test proves nothing (\(first.focusAskState))")

        // The pane shows the new tab in the first page's place: its content view enters the window (the pane host's
        // view moves into it, the keyboard with it), and the first page's leaves.
        let joining = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        joining.contentView.frame = frame
        host.add(joining)
        let url = try #require(URL(string: address))
        joining.load(url)
        root.addSubview(joining.contentView)
        first.contentView.removeFromSuperview()
        // The focus model's target is the new page (the focus applier: in tree, the page does not have the keyboard).
        joining.setFocused(true)
        try #require(joining.browserID == nil && joining.pendingFocus,
                     "the new tab had a browser or kept no ask: the order of the bug is not reproduced (\(joining.focusAskState))")
        CEFInTreeFirstLoadFocusTests.endTurn() // the tab joins the pane's window after the frame commits

        let container = try #require(host.hostView.inTree.container)
        try #require(joining.browserID == joiningBrowser && host.visibleTab === joining,
                     "the new tab did not join the pane's live window: \(joining.focusAskState)")
        try #require(chromium.pages[joiningBrowser]?.contents.superview === container && firstView.window == nil,
                     "Chromium did not show the new tab in tree in the first page's place: the test proves nothing")
        return Join(chromium: chromium, host: host, first: first, joining: joining, firstView: firstView)
    }

    /// In-tree pages on, a runtime with the stand-in shim, and a cmux window with an omnibar field.
    static func withCmuxWindow(_ body: (CEFRuntime, CmuxWindow, KeyView) throws -> Void) throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        let (runtime, root) = try JoiningTabShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { JoiningTabShim.reset() }
        let window = CmuxWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 340), styleMask: .borderless,
                                backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let omnibar = KeyView(frame: NSRect(x: 0, y: 310, width: 800, height: 30))
        try #require(window.contentView).addSubview(omnibar)
        try body(runtime, window, omnibar)
    }

    /// The failing order: the new tab joins the pane's live window, Chromium shows it in the first page's place, the
    /// navigation makes its view, Chromium's restore and CEF's ask come while no view has the keyboard, and the page's
    /// first load ends. The new page's view ends with the keyboard.
    @Test func aTabThatJoinsItsPanesLiveWindowGetsTheKeyboardByItsFirstLoad() throws {
        try Self.withCmuxWindow { runtime, window, _ in
            let join = try Self.join(runtime, in: window, frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            try #require(window.firstResponder !== join.firstView, "the first page's view kept the keyboard out of the window")

            // The window itself took the keyboard: the focus model asks for the page again (journal: responder
            // windowOrNone, then focus(true) created=true shown=true).
            join.joining.setFocused(true)

            // The navigation makes the page's view; Chromium's focus restore and CEF's ask after the navigation.
            let view = try #require(join.chromium.navigationMakesItsView(Self.joiningBrowser))
            join.chromium.focus(Self.joiningBrowser)
            Self.chromiumAsksForFocus(Self.joiningBrowser, .navigation, runtime, join.chromium)

            // The page's first load ends with its first paint.
            CEFDeferredFocusTests.load(runtime, Self.joiningBrowser, Self.address)
            #expect(window.firstResponder === view,
                    "the joining tab's view never took the keyboard: keys typed with no click reach no page (first responder \(String(describing: window.firstResponder)), \(join.joining.focusAskState))")
            #expect(join.joining.pageReady, "the page is not ready for keys after its first load: \(join.joining.focusAskState)")
        }
    }

    /// The rule's other side: the person moved the keyboard before the page's first load ended (the omnibar, a
    /// terminal, another pane's page). The focus model drops the page's ask (`FocusEffectApplier.dropInTreeFocusAsk`),
    /// and the page never takes the keyboard from there: not at its first load, not by Chromium's restore or ask.
    @Test func aJoiningTabNeverTakesTheKeyboardFromWhereThePersonMovedIt() throws {
        for holderKind in ["omnibar", "terminal", "another pane's page"] {
            try Self.withCmuxWindow { runtime, window, omnibar in
                let join = try Self.join(runtime, in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                let root = try #require(window.contentView)
                let holder: NSView
                switch holderKind {
                case "omnibar":
                    holder = omnibar
                case "terminal":
                    holder = KeyView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
                    root.addSubview(holder)
                default:
                    let other = try CEFInTreeFirstLoadFocusTests.pane(runtime, browser: 83, in: window,
                                                                       frame: NSRect(x: 400, y: 0, width: 400, height: 300))
                    holder = other.page.navigationMakesItsView()
                }
                try #require(FocusRoute(.person, "the person moves the keyboard").moveKeyboard(in: window, to: holder),
                             "the \(holderKind) did not take the keyboard: the test proves nothing")
                join.joining.dropFocusAsk()

                let view = try #require(join.chromium.navigationMakesItsView(Self.joiningBrowser))
                join.chromium.focus(Self.joiningBrowser)
                #expect(!Self.chromiumAsksForFocus(Self.joiningBrowser, .navigation, runtime, join.chromium),
                        "a navigation ask took the keys from the \(holderKind)")
                CEFDeferredFocusTests.load(runtime, Self.joiningBrowser, Self.address)
                #expect(window.firstResponder === holder,
                        "the joining tab took the keyboard from the \(holderKind) (first responder \(String(describing: window.firstResponder)))")
                #expect(window.firstResponder !== view)
            }
        }
    }

    /// A joining tab that is not shown when its first load ends (the content lifecycle hid it: a workspace switch) does
    /// not take the keyboard then; the page's ask is kept, and it takes the keyboard once it shows again.
    @Test func aJoiningTabHiddenAtItsFirstLoadTakesTheKeyboardOnlyOnceShown() throws {
        try Self.withCmuxWindow { runtime, window, _ in
            let join = try Self.join(runtime, in: window, frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            let view = try #require(join.chromium.navigationMakesItsView(Self.joiningBrowser))
            join.chromium.focus(Self.joiningBrowser)
            Self.chromiumAsksForFocus(Self.joiningBrowser, .navigation, runtime, join.chromium)

            join.joining.setContentVisible(false)
            CEFInTreeFirstLoadFocusTests.endTurn() // the host hides at the end of the turn
            CEFDeferredFocusTests.load(runtime, Self.joiningBrowser, Self.address)
            #expect(window.firstResponder !== view, "a hidden page's view took the keyboard at its first load")
            #expect(!Self.chromiumAsksForFocus(Self.joiningBrowser, .system, runtime, join.chromium),
                    "a hidden page's ask was allowed")

            join.joining.setContentVisible(true)
            #expect(window.firstResponder === view,
                    "the joining tab did not take the keyboard once shown again (first responder \(String(describing: window.firstResponder)), \(join.joining.focusAskState))")
        }
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the browser started, `cmux_shim_tab_add` hands the call
/// to the test's Chromium window (`onTabAdd`), `cmux_shim_tab_activate` reports success, and `cmux_shim_set_focus`
/// records the browsers cmux gives focus and runs `onGrant` (CEF's `SetFocus(true)`); every other function does nothing.
nonisolated enum JoiningTabShim {
    nonisolated(unsafe) static var granted: [Int32] = []
    nonisolated(unsafe) static var onGrant: ((Int32) -> Void)?
    nonisolated(unsafe) static var onTabAdd: ((Bool) -> Int32)?
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    @MainActor static func runtime() throws -> (CEFRuntime, URL) {
        reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-join-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        return (runtime, root)
    }

    static func reset() {
        granted = []
        onGrant = nil
        onTabAdd = nil
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, activate in
            JoiningTabShim.onTabAdd?(activate == 1) ?? 0
        }
        let tabActivate: @convention(c) (Int32) -> Int32 = { _ in 1 }
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focused in
            if focused == 1 {
                JoiningTabShim.granted.append(browser)
                JoiningTabShim.onGrant?(browser)
            }
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_focus": unsafeBitCast(setFocus, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
