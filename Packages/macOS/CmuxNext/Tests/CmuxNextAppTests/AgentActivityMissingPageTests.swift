import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextPages
import CmuxNextWakeups
import Testing
import WebKit

/// The `cmux://agent-activity` tab when the page host has no root for the Activity page (its files
/// are missing from the bundle): the browser pane's standard load error page, and no WebKit view of
/// the tab's own (p13-webui-075 deleted the `AgentActivityHostView` fallback).
@MainActor
struct AgentActivityMissingPageTests {
    @Test func aMissingActivityPageShowsTheLoadErrorPage() {
        // The page host finds no root for the Activity page, whatever the process-wide page roots hold.
        var asked: [PageDescriptor] = []
        let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        let tab = AgentActivityPageTab(id: BrowserTabID(rawValue: "activity"), engine: .webkit, profile: .default,
                                       source: AgentActivityMockSource(), openPage: { asked.append($0.descriptor); return nil },
                                       deadlines: deadlines)
        defer { tab.close() }

        #expect(asked.map(\.id) == [PageDescriptor.agentActivity.id])
        #expect(tab.state.loadError == AgentActivityPageTab.missingPage)
        #expect(!(tab.contentView is PageWebView))
        #expect(!Self.holdsWebView(tab.contentView))

        // What the pane draws over its content for that state: the load error page with the message,
        // and no Try Again (another open finds no root either).
        let status = PageStatusViews()
        status.install(in: NSView(), tab: { tab })
        status.render(tab.state)
        #expect(!status.errorView.isHidden)
        #expect(!status.errorView.isCertificateInterstitial)
        #expect(status.errorView.retryButton.isHidden)
        #expect(status.errorView.debugText.contains(AgentActivityPaneStrings.pageMissing))
    }

    /// Any other failed load still offers Try Again.
    @Test func aRetryableLoadErrorKeepsTryAgain() {
        let view = LoadErrorView()
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "offline",
                                   failingURL: URL(string: "https://example.com")))
        #expect(!view.retryButton.isHidden)
    }

    private static func holdsWebView(_ view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains(where: holdsWebView)
    }
}
