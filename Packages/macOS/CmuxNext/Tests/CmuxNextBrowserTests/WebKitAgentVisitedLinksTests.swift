import AppKit
@testable import CmuxNextBrowser
import Testing
import CmuxNextTestSupport
import WebKit

/// RFD 0125 D5: an agent's visits never colour a link as visited, and they name the agent in history.
/// A WebKit tab never took the agent mark, so its agent visits were the person's and coloured links.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct WebKitAgentVisitedLinksTests {
    @Test func anAgentMarkNamesTheSessionAndStopsVisitedLinks() throws {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        try #require(WebKitVisitedLinks.adds(page.webView) != nil, "this WebKit has no _addsVisitedLinks")
        #expect(!page.isAgentDriven)
        #expect(WebKitVisitedLinks.adds(page.webView) == true)

        page.markAgent(reading: false, session: "s-1")
        #expect(page.isAgentDriven)
        #expect(page.agentSessionID == "s-1")
        #expect(WebKitVisitedLinks.adds(page.webView) == false)
    }

    @Test func aReadMarksThePageToo() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        page.markAgent(reading: true, session: nil)
        #expect(page.isAgentDriven)
        #expect(page.agentSessionID == nil)
        #expect(WebKitVisitedLinks.adds(page.webView) != true)
    }

    /// The person's tab adds the page it loads to its visited-link store; the agent's tab does not.
    @Test func onlyThePersonsLoadBecomesAVisitedLink() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("visited.html")
        try Data("<title>v</title>".utf8).write(to: target)

        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let person = engine.makeWebKitTab(), agent = engine.makeWebKitTab()
        defer { person.close(); agent.close() }
        agent.markAgentDriven()
        for page in [person, agent] { page.webView.loadFileURL(target, allowingReadAccessTo: dir) }
        let deadline = ContinuousClock.now + .seconds(20)
        while [person, agent].contains(where: { page in page.webView.isLoading || page.webView.url.map { $0 != target } ?? true }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let personVisited = try #require(Self.visitedLinkStoreContains(person.webView, target), "no _visitedLinkStore")
        let agentVisited = try #require(Self.visitedLinkStoreContains(agent.webView, target))
        #expect(personVisited, "the person's load was not added as a visited link (the test reads the wrong store)")
        #expect(!agentVisited, "the agent's load coloured links as visited")
    }

    /// `configuration._visitedLinkStore` (`_WKVisitedLinkStore`) `containsVisitedLinkWithURL:`; nil without it.
    private static func visitedLinkStoreContains(_ webView: WKWebView, _ url: URL) -> Bool? {
        let configuration = webView.configuration
        guard configuration.responds(to: NSSelectorFromString("_visitedLinkStore")),
              let store = configuration.value(forKey: "_visitedLinkStore") as? NSObject else { return nil }
        let contains = NSSelectorFromString("containsVisitedLinkWithURL:")
        guard store.responds(to: contains), let method = store.method(for: contains) else { return nil }
        typealias Contains = @convention(c) (AnyObject, Selector, NSURL) -> Bool
        return unsafeBitCast(method, to: Contains.self)(store, contains, url as NSURL)
    }
}
