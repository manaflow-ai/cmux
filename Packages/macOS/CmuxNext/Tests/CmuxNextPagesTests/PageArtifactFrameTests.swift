@testable import CmuxNextPages
import Foundation
import Testing

@MainActor
struct PageArtifactFrameTests {
    private let page = PageDescriptor(id: "cmux.agent", resource: "agent-pane", namespaces: [])

    @Test func artifactEndpointUsesOpaqueSandboxAndOneShotBootstrap() async throws {
        let handler = PageSchemeHandler(page: page, root: URL(fileURLWithPath: "/missing"), devServer: nil)
        let url = try #require(URL(string: "cmux-page://cmux.agent/__artifact"))
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.response.statusCode == 200)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("sandbox allow-scripts") == true)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("allow-same-origin") == false)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("connect-src 'none'") == true)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-src 'none'") == true)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("form-action 'none'") == true)
        #expect(String(decoding: reply.body, as: UTF8.self).contains("cmux-render-ready"))
        #expect(await handler.reply(to: URL(string: "cmux-page://cmux.agent/__artifact?copy=1")!) == nil)
    }

    @Test func artifactNavigationAllowsOnlyDirectBlankChildAndInitialSrcdoc() throws {
        let endpoint = try #require(URL(string: "cmux-page://cmux.agent/__artifact"))
        let pageURL = try #require(URL(string: "cmux-page://cmux.agent/"))
        let blank = try #require(URL(string: "about:blank"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        let external = try #require(URL(string: "https://example.test/"))

        #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: pageURL, hook: nil) == .allow)
        #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: false, mainFrame: true,
                                      targetFrameURL: blank, sourceFrameURL: nil, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: endpoint, sourceFrameURL: pageURL, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: pageURL, hook: nil) == .allow)
        #expect(PageNavigation.policy(for: external, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: endpoint, sourceFrameURL: pageURL, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: srcdoc, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: pageURL, hook: nil) == .allow)
        #expect(PageNavigation.policy(for: srcdoc, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: srcdoc, sourceFrameURL: pageURL, hook: nil) == .allow)
        #expect(PageNavigation.policy(for: external, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: srcdoc, sourceFrameURL: pageURL, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: external, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: srcdoc, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: external, page: page, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: srcdoc, hook: { _ in .allow }) == .cancel)
    }

    @Test func ordinaryPageNavigationKeepsExistingPolicy() throws {
        let pageURL = try #require(URL(string: "cmux-page://cmux.agent/"))
        let otherPage = try #require(URL(string: "cmux-page://cmux.agent/other.html"))
        let external = try #require(URL(string: "https://example.test/"))
        #expect(PageNavigation.policy(for: pageURL, page: page, userClicked: false, mainFrame: true, hook: nil) == .allow)
        #expect(PageNavigation.policy(for: otherPage, page: page, userClicked: false, mainFrame: true, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: external, page: page, userClicked: true, mainFrame: true, hook: nil) == .openExternal)
    }

    @Test func ordinaryPageSrcdocStillReachesNavigationHook() throws {
        let ordinary = PageDescriptor(id: "cmux.history", resource: "history", namespaces: [])
        let pageURL = try #require(URL(string: "cmux-page://cmux.history/"))
        let blank = try #require(URL(string: "about:blank"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        #expect(PageNavigation.policy(for: srcdoc, page: ordinary, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: pageURL,
                                      hook: { _ in .allow }) == .allow)
    }
}
