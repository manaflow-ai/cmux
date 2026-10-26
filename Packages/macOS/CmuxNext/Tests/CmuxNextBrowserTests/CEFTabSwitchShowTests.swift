import AppKit
@testable import CmuxNextBrowser
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// The browser's side of `switch.tab` (p09-observability task 028): a Chromium page's switch ends at its page
/// window's show (`CEFLayerHosting.pageShown`), hosted or not, and the kind a switch reports for each page.
@MainActor
@Suite struct CEFTabSwitchShowTests {
    private let pane = NSObject()

    /// A signpost whose commit boundary fires at once (the end lands in the same call).
    private func makeSignpost() -> TabSwitchSignpost {
        TabSwitchSignpost(signposter: Signposter(category: .switch, trace: TraceRuntime(role: .app))) { $0(.committed) }
    }

    @Test func aPageShowEndsTheSwitchWaitingForItEvenBeforeThePageWindowExists() throws {
        let signpost = makeSignpost()
        signpost.began(pane, kind: .page, inputAgeMilliseconds: -1)
        let show = try #require(signpost.pageShow(pane))
        // The pane's content commit does not end a page's switch.
        signpost.contentShown(pane)
        #expect(signpost.openCount == 1)
        // No page window yet (no fork call to make): the show still ends it.
        CEFLayerHosting(isEnabled: { true }, schedule: { $0() }).pageShown(browser: 3, tabSwitch: show)
        #expect(signpost.openCount == 0)
    }

    @Test func aHostedPagesShowEndsItsSwitchOnce() throws {
        let signpost = makeSignpost()
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { $0() },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        hosting.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hosting.pageWindowCreated(browser: 3, fork: CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 }))
        #expect(hosting.page != nil)
        signpost.began(pane, kind: .page, inputAgeMilliseconds: -1)
        let show = try #require(signpost.pageShow(pane))
        hosting.pageShown(browser: 4, tabSwitch: show)
        #expect(signpost.openCount == 0)
        // The next switch is not ended by the old request.
        signpost.began(pane, kind: .page, inputAgeMilliseconds: -1)
        hosting.pageShown(browser: 3, tabSwitch: show)
        #expect(signpost.openCount == 1)
    }

    @Test func eachPageReportsItsKind() {
        let signpost = makeSignpost()
        let live = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        #expect(signpost.kind(of: live) == .warm)
        let deferred = DeferredBrowserTab(id: BrowserTabID(rawValue: "tab_1"), engine: .cef, url: nil, title: nil)
        #expect(signpost.kind(of: deferred) == .cold)
    }

    @Test func aPageThatIsNotChromiumTakesNoRequest() {
        let signpost = makeSignpost()
        let live = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        signpost.began(pane, kind: .warm, inputAgeMilliseconds: -1)
        signpost.shows(live, for: pane)
        // Not waiting for a page: the pane's content commit ends it.
        signpost.contentShown(pane)
        #expect(signpost.openCount == 0)
    }
}
