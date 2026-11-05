@testable import CmuxNextPages
import Foundation
import Testing

/// Both first-party surfaces use the same canonical opaque document. The pane gets no access
/// to any other resource on the agent origin, and the document gets no native capability.
@MainActor
struct PageArtifactsParentTests {
    private let endpoint = URL(string: "cmux-page://cmux.agent/__artifact")
    private let pane = PageDescriptor(id: "cmux.artifacts", resource: "artifacts", namespaces: [])
    private let root = URL(fileURLWithPath: "/missing")

    @Test func paneServesOnlyCanonicalEndpoint() async throws {
        let endpoint = try #require(self.endpoint)
        let handler = PageSchemeHandler(page: pane, root: root, devServer: nil)
        let reply = try #require(await handler.reply(to: endpoint))
        #expect(reply.response.statusCode == 200)
        let policy = try #require(reply.response.value(forHTTPHeaderField: "Content-Security-Policy"))
        #expect(policy.contains("sandbox allow-scripts;"))
        #expect(!policy.contains("allow-same-origin"))
        #expect(policy.contains("frame-ancestors cmux-page://cmux.agent cmux-page://cmux.artifacts"))
        for directive in ["connect-src 'none'", "frame-src 'none'", "worker-src 'none'", "form-action 'none'", "base-uri 'none'"] {
            #expect(policy.contains(directive))
        }
        #expect(PageSchemeHandler.route(for: endpoint, page: pane, root: root) == .artifact)
        for text in ["cmux-page://cmux.agent/", "cmux-page://cmux.agent/bridge.js",
                     "cmux-page://cmux.agent/__artifact?copy=1", "cmux-page://cmux.agent/__artifact#copy",
                     "cmux-page://cmux.agent:443/__artifact", "cmux-page://user@cmux.agent/__artifact",
                     "cmux-page://cmux.agent/%5f%5fartifact"] {
            let url = try #require(URL(string: text))
            #expect(await handler.reply(to: url) == nil)
            #expect(PageSchemeHandler.route(for: url, page: pane, root: root) == nil)
        }
        #expect(!PageArtifactFrame.isFrame(URL(string: "cmux-page://cmux.artifacts/__artifact")))
    }

    @Test func canonicalEndpointLoadsOnlyInDirectBlankChildOfAllowedParent() throws {
        let endpoint = try #require(self.endpoint)
        for id in ["cmux.agent", "cmux.artifacts", "cmux.history", "org.example.page"] {
            let page = PageDescriptor(id: id, resource: "fixture", namespaces: [])
            let parent = try #require(URL(string: "cmux-page://\(id)/"))
            let blank = try #require(URL(string: "about:blank"))
            let allowed = id == "cmux.agent" || id == "cmux.artifacts"
            #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: false, mainFrame: false,
                                          targetFrameURL: blank, sourceFrameURL: parent, hook: nil) == (allowed ? .allow : .cancel))
            #expect(PageNavigation.policy(for: endpoint, page: page, userClicked: true, mainFrame: true,
                                          targetFrameURL: blank, sourceFrameURL: parent, hook: { _ in .allow }) == .cancel)
        }
        for text in ["https://cmux.artifacts/", "cmux-page://cmux.artifacts.evil/", "cmux-page://user@cmux.artifacts/",
                     "cmux-page://cmux.artifacts:443/", "file:///tmp/artifacts", "about:srcdoc"] {
            #expect(PageNavigation.policy(for: endpoint, page: pane, userClicked: false, mainFrame: false,
                                          targetFrameURL: nil, sourceFrameURL: URL(string: text), hook: { _ in .allow }) == .cancel)
        }
    }

    @Test func artifactAndSrcdocCannotNavigateOrCreateNestedFrames() throws {
        let endpoint = try #require(self.endpoint)
        let parent = try #require(URL(string: "cmux-page://cmux.artifacts/"))
        let blank = try #require(URL(string: "about:blank"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        #expect(PageNavigation.policy(for: srcdoc, page: pane, userClicked: false, mainFrame: false,
                                      targetFrameURL: blank, sourceFrameURL: parent, hook: nil) == .allow)
        for text in [endpoint.absoluteString, endpoint.absoluteString + "?again", "cmux-page://cmux.artifacts/",
                     "cmux-page://cmux.agent/bridge.js", "https://example.test/", "file:///tmp/private",
                     "data:text/html,escape", "about:blank", "about:srcdoc"] {
            let target = try #require(URL(string: text))
            for restricted in [endpoint, srcdoc] {
                for mainFrame in [true, false] {
                    // A direct child navigates itself, asks to replace the top document, or
                    // creates a nested child. Even a permissive embedding hook cannot allow it.
                    #expect(PageNavigation.policy(for: target, page: pane, userClicked: true, mainFrame: mainFrame,
                                                  targetFrameURL: restricted, sourceFrameURL: restricted,
                                                  hook: { _ in .allow }) == .cancel)
                    #expect(PageNavigation.policy(for: target, page: pane, userClicked: false, mainFrame: false,
                                                  targetFrameURL: blank, sourceFrameURL: restricted,
                                                  hook: { _ in .allow }) == .cancel)
                }
                let message = PageHostMessage(frameURL: restricted, isMainFrame: false, body: ["op": "cmux.artifacts.file"])
                #expect(!PageHostTrust.isTrusted(message, page: pane))
            }
        }
    }
}
