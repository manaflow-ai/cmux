import AppKit
import CmuxNextPages
import Testing
@testable import CmuxNextApp

/// Follow-up of #29386 (review note 3): the docked Home's Channels page is a page INSIDE the dock's view
/// (`HomeDockView`, a ``PageWebViewContainer``), not the tab's content itself. #29386 taught
/// `TabContent.childWindowTab` to find it through ``PageWebView/shown(in:)``; the key router's focused page
/// and the tab's focus target still looked for `content as? PageWebView` only, so for Channels the focus
/// target was the dock view (it takes no keys), not the page. Those readers must find the page a container
/// shows, by the same rule. The type-ahead must not (see its test).
@MainActor
struct HomeDockChannelsPageReadersTests {
    /// A container like the docked Home in Channels mode: it shows a page inside its own view.
    final class Dock: NSView, PageWebViewContainer {
        var page: PageWebView?
        var shownPageView: PageWebView? { page }
    }

    private func dockShowingPage() throws -> (InternalPageView, PageWebView) {
        let page = try #require(PageWebView(descriptor: PageDescriptor(id: "test.dock-readers", resource: "files", namespaces: []), routes: []))
        let dock = Dock(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        dock.page = page
        dock.addSubview(page)
        return (InternalPageView(key: "tab_dock", page: .homeDock, content: dock), page)
    }

    /// Review of #33869 (FIX at 181170d6294): the Channels page focuses no input when it opens, so its readiness stays
    /// not ready until the person focuses a field. A type-ahead hold on it held and then dropped the page's own bare keys
    /// (j, k, r, t, c, e). The type-ahead must not read a page that a container shows.
    @Test func theTypeAheadDoesNotHoldKeysForThePageTheDockShows() throws {
        let (view, _) = try dockShowingPage()
        #expect(TabContent.page(view).inputReadiness == nil, "the type-ahead would hold Channels' own bare keys")
    }

    @Test func theTabsFocusTargetIsThePageTheDockShows() throws {
        let (view, page) = try dockShowingPage()
        #expect(view.focusTarget === page.focusView, "the tab's focus target is the dock view, not the Channels page")
    }

    @Test func aPageTabIsStillItsOwnPage() throws {
        let page = try #require(PageWebView(descriptor: PageDescriptor(id: "test.dock-readers-own", resource: "files", namespaces: []), routes: []))
        let view = InternalPageView(key: "tab_page", page: .homeTab, content: page)
        #expect(TabContent.page(view).inputReadiness === page.inputReadiness)
        #expect(view.focusTarget === page.focusView)
    }
}
