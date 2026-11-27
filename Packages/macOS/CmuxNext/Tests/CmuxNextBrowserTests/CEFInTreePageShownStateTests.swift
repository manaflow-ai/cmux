import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// In-tree pages (fork API 36) have no page window: the page's WebContentsViewCocoa is a subview of cmux's own window,
/// in the pane host's in-tree container. Three readers still looked only for a child page window over the tab, so they
/// read every in-tree page as one with no page:
///
/// - `CEFTab.contentVisibility` read `.hidden("page_window_missing")` for every in-tree page, painting or not. So
///   `debug.surfaces` reported each browser pane `blank: true`, `blank_reason: page_hidden`, and the blank-pane invariant
///   logged a fault for it on every pane change (views-window design note, other-Mac run vw4a-diag-ctl-r1: blank_panes 4
///   while all four pages painted, visibilityState visible, about 120 rAF ticks a second).
/// - The key router's page question (`CEFTab.pageHasKeyboard(in:)`, read by `KeyRouter.pageHasKeys`) answered no for an
///   in-tree page that had the keyboard. cmux then ran Find (and its neighbors) before the page, so a page with its own
///   Cmd-F, such as Google Sheets, never got the key (Lawrence 2026-10-23), and a cmux page's `hasKeys` was always false.
/// - The caret accessory's check (`CEFRuntime.showsCmuxPage`) never matched a cmux page in tree, so macOS drew its caret
///   bubble over the Chief composer's + button again (Leo 2026-10-21).
///
/// In tree, the page's own hosting answers: its view in the container, in the window, not hidden; the window's first
/// responder in the container. NIGHTLY's child-window mode keeps its page-window answers.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFInTreePageShownStateTests {
    typealias Rig = CEFInTreeFirstLoadFocusTests

    static let left = NSRect(x: 0, y: 0, width: 400, height: 300)
    static let right = NSRect(x: 400, y: 0, width: 400, height: 300)

    /// A shown in-tree page whose navigation made its view reads visible, as the pane shows it.
    @Test func aPaintingInTreePageReadsVisible() throws {
        try Rig.withCmuxWindow { runtime, window, _ in
            let pane = try Rig.pane(runtime, browser: 91, in: window, frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            pane.page.navigationMakesItsView()
            try #require(pane.page.contents.window === window && !pane.page.contents.isHiddenOrHasHiddenAncestor,
                         "the stand-in page does not show in the cmux window: the test proves nothing")
            let visibility = pane.tab.contentVisibility
            #expect(visibility.isVisible, "a painting in-tree page reads hidden: \(visibility.reason ?? "-")")
            #expect(visibility.reason == nil)
        }
    }

    /// The other side: an in-tree page that does not show still reads hidden, with why.
    @Test func anInTreePageThatDoesNotShowReadsHidden() throws {
        try Rig.withCmuxWindow { runtime, window, _ in
            let hidden = try Rig.pane(runtime, browser: 92, in: window, frame: Self.left)
            hidden.page.navigationMakesItsView()
            hidden.page.contents.isHidden = true
            #expect(!hidden.tab.contentVisibility.isVisible, "a hidden page view reads visible")

            let gone = try Rig.pane(runtime, browser: 93, in: window, frame: Self.right)
            gone.page.navigationMakesItsView()
            gone.host.hostView.inTree.stop() // the page left the tree: none of it is in the window
            try #require(gone.page.contents.window == nil)
            #expect(!gone.tab.contentVisibility.isVisible, "a page out of the tree reads visible")

            let concealed = try Rig.pane(runtime, browser: 94, in: window, frame: Self.left)
            concealed.page.navigationMakesItsView()
            concealed.tab.setContentVisible(false)
            Rig.endTurn() // the host hides at the end of the turn
            #expect(concealed.tab.contentVisibility == .hidden("host_hidden"))

            let removed = try Rig.pane(runtime, browser: 95, in: window, frame: Self.right)
            removed.tab.contentView.removeFromSuperview()
            #expect(removed.tab.contentVisibility == .hidden("not_in_window"))
        }
    }

    /// The key router's question: an in-tree page has the keyboard while the cmux window's first responder is in its
    /// container; never while the omnibar has it, never another pane's page, never in another window.
    @Test func anInTreePageWithTheKeyboardIsTheOneTheKeysGoTo() throws {
        try Rig.withCmuxWindow { runtime, window, omnibar in
            let left = try Rig.pane(runtime, browser: 96, in: window, frame: Self.left)
            let right = try Rig.pane(runtime, browser: 97, in: window, frame: Self.right)
            left.page.navigationMakesItsView()
            right.page.navigationMakesItsView()
            try #require(window.makeFirstResponder(omnibar))
            #expect(!left.tab.pageHasKeyboard(in: window), "the omnibar has the keyboard, not the page")
            #expect(!right.tab.pageHasKeyboard(in: window))

            left.tab.setFocused(true)
            let holder = try #require(window.firstResponder as? NSView)
            let container = try #require(left.container)
            try #require(holder.isDescendant(of: container), "the page did not take the keyboard: the test proves nothing")
            #expect(left.tab.pageHasKeyboard(in: window), "an in-tree page with the keyboard is not the one the keys go to")
            #expect(!right.tab.pageHasKeyboard(in: window), "another pane's page counts as having the keyboard")

            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless,
                                 backing: .buffered, defer: true)
            defer { other.closeAfterTest() }
            #expect(!left.tab.pageHasKeyboard(in: other), "another window's keys counted for the page")
        }
    }

    /// The caret accessory: a view in a cmux page's in-tree container hides macOS's caret bubble; a web page's view and a
    /// view outside any page keep it.
    @Test func aCmuxPageInTreeHidesTheCaretAccessory() throws {
        try Rig.withCmuxWindow { runtime, window, omnibar in
            let cmuxPage = try Rig.pane(runtime, browser: 98, in: window, frame: Self.left)
            let webPage = try Rig.pane(runtime, browser: 99, in: window, frame: Self.right)
            for pane in [cmuxPage, webPage] { runtime.hosts[pane.host.key] = pane.host }
            defer { for pane in [cmuxPage, webPage] { runtime.hosts[pane.host.key] = nil } }
            cmuxPage.tab.pageThemeSurface = .agentPane
            let caretView = cmuxPage.page.navigationMakesItsView()
            let webView = webPage.page.navigationMakesItsView()
            #expect(runtime.showsCmuxPage(caretView), "a cmux page's view in tree keeps the caret bubble")
            #expect(!runtime.showsCmuxPage(webView), "a web page's view lost the caret bubble")
            #expect(!runtime.showsCmuxPage(omnibar))
        }
    }

    /// NIGHTLY's child-window mode keeps its page-window answers: visible only with a page window at the host's place,
    /// and that window is the one whose keys reach the page.
    @Test func aChildWindowPageKeepsItsPageWindowAnswers() throws {
        InTreePages.shared.setForTesting(requested: false)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 800, height: 340), styleMask: .borderless,
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.orderFrontRegardless()
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: 100, request: request, window: 1))
        try #require(window.contentView).addSubview(tab.contentView)
        try #require(tab.presentation == .childWindow && host.visibleTab === tab && host.hostView.superview === tab.contentView,
                     "the tab does not show in child-window mode: the test proves nothing")
        #expect(tab.contentVisibility == .hidden("page_window_missing"), "no page window over the tab")

        let rect = window.convertToScreen(host.hostView.convert(host.hostView.bounds, to: nil))
        try #require(rect.width >= 1 && rect.height >= 1, "the host view has no room: \(rect)")
        let page = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        window.addChildWindow(page, ordered: .above)
        defer {
            window.removeChildWindow(page)
            page.closeAfterTest()
        }
        page.orderFront(nil)
        try #require(page.isVisible && page.parent === window)
        #expect(tab.contentVisibility == .visible, "a page window at the host's place: \(tab.contentVisibility.reason ?? "-")")
        #expect(tab.pageHasKeyboard(in: page), "the page window's keys reach the page")
        #expect(!tab.pageHasKeyboard(in: window), "the cmux window's keys counted for a child-window page")

        runtime.hosts[host.key] = host
        defer { runtime.hosts[host.key] = nil }
        tab.pageThemeSurface = .agentPane
        let caret = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        try #require(page.contentView).addSubview(caret)
        #expect(runtime.showsCmuxPage(caret), "a cmux page's view in its page window keeps the caret bubble")
        let shell = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        try #require(window.contentView).addSubview(shell)
        #expect(!runtime.showsCmuxPage(shell))
    }
}
