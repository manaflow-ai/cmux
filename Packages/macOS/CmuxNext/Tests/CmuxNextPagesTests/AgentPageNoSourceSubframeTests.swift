@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// On the agent page, a load into a frame inside the page with no source frame is cancelled: an
/// unknown source is denied, as the agent pane's navigation rules deny it. macOS 14's WebKit gives
/// no source frame for some navigations (#36290); read as a nil source URL, it skipped the checks
/// that cancel the same load from a known source (a srcdoc frame sent to another document of the
/// page). The main frame's own document still loads with no source frame (the launch load).
@MainActor
struct AgentPageNoSourceSubframeTests {
    private let page = PageDescriptor(id: "cmux.agent", resource: "agent", namespaces: [])

    @Test func theAgentPagePolicyCancelsASubframeLoadWithNoSource() throws {
        let pageURL = try #require(URL(string: "cmux-page://cmux.agent/"))
        let other = try #require(URL(string: "cmux-page://cmux.agent/other.html"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        let blank = try #require(URL(string: "about:blank"))

        // A srcdoc frame sent to another document of the page: cancelled from a known source, so
        // also with none.
        #expect(PageNavigation.policy(for: other, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: srcdoc, sourceFrameURL: pageURL, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: other, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: srcdoc, sourceFrameURL: nil, hook: nil) == .cancel)
        // Any frame inside the agent page: no source, no load, whatever a hook would say.
        #expect(PageNavigation.policy(for: other, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: nil, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: srcdoc, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: nil, sourceFrameURL: nil, hook: { _ in .allow }) == .cancel)
        // The main frame's own document still loads with no source frame (the launch load).
        #expect(PageNavigation.policy(for: pageURL, page: page, userClicked: false, mainFrame: true,
                                      sourceFrameURL: nil, hook: nil) == .allow)
    }

    @Test func theAgentPageDelegateCancelsASubframeLoadWithNoSourceFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-no-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Agent</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let view = try #require(PageWebView(descriptor: page, root: root, testRoot: true, routes: [], chromium: hosting))
        defer { view.close() }
        let other = try #require(URL(string: "cmux-page://cmux.agent/other.html"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))

        let intoSrcdoc = FakeNavigationAction(url: other, targetFrame: FakeFrameInfo(url: srcdoc, isMainFrame: false))
        #expect(await view.webView(view.webView, decidePolicyFor: intoSrcdoc) == .cancel)
        #expect(await view.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: page.url())) == .allow)
    }
}
