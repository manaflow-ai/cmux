import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneArtifactNavigationTests {
    @Test func artifactsCannotNavigateEvenToAnotherAllowedFrame() throws {
        let pane = AgentPaneSource.bundled(try #require(URL(string: "cmux-agent://pane/index.html")))
        let frame = try #require(URL(string: "cmux-agent://render/artifact"))
        #expect(AgentPaneNavigation.decision(for: frame, source: pane, userClicked: false, mainFrame: false,
                                             sourceFrameURL: pane.pageURL) == .allow)
        for text in ["http://127.0.0.1:8080/leak", "https://example.com", "file:///tmp/private", "cmux-agent://render/frame", "about:srcdoc"] {
            let url = try #require(URL(string: text))
            for main in [true, false] {
                #expect(AgentPaneNavigation.decision(for: url, source: pane, userClicked: true, mainFrame: main,
                                                     sourceFrameURL: frame) == .cancel)
                #expect(AgentPaneNavigation.decision(for: url, source: pane, userClicked: false, mainFrame: main,
                                                     targetFrameURL: frame) == .cancel)
            }
        }
    }

    @Test func srcdocArtifactCannotNavigateOutOfItsSandbox() throws {
        let pane = AgentPaneSource.bundled(try #require(URL(string: "cmux-agent://pane/index.html")))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        for text in ["http://127.0.0.1:8080/leak", "https://example.com", "file:///tmp/private", "cmux-agent://pane/index.html"] {
            let url = try #require(URL(string: text))
            #expect(AgentPaneNavigation.decision(for: url, source: pane, userClicked: true, mainFrame: false,
                                                 sourceFrameURL: srcdoc, targetFrameURL: srcdoc) == .cancel)
        }
        // The parent is allowed to create its srcdoc child; only a navigation that originated there is refused.
        #expect(AgentPaneNavigation.decision(for: srcdoc, source: pane, userClicked: false, mainFrame: false) == .allow)
    }

    @Test func onlyTheTrustedPaneMayCreateAnArtifactFrame() throws {
        let pane = AgentPaneSource.bundled(try #require(URL(string: "cmux-agent://pane/index.html")))
        let artifact = try #require(URL(string: "cmux-agent://render/artifact"))
        let render = try #require(URL(string: "cmux-agent://render/frame"))
        for text in ["http://127.0.0.1:8080/preview", "https://example.com/", "cmux-agent://pane/other.html", "about:blank"] {
            let untrusted = try #require(URL(string: text))
            #expect(AgentPaneNavigation.decision(for: artifact, source: pane, userClicked: false, mainFrame: false,
                                                 sourceFrameURL: untrusted) == .cancel)
            // Ordinary render cards keep their existing navigation policy.
            #expect(AgentPaneNavigation.decision(for: render, source: pane, userClicked: false, mainFrame: false,
                                                 sourceFrameURL: untrusted) == .allow)
        }
        #expect(AgentPaneNavigation.decision(for: artifact, source: pane, userClicked: false, mainFrame: false) == .cancel)
        // The pane creates a fresh child whose target request may still be empty or about:blank.
        for target in [nil, URL(string: "about:blank")] {
            #expect(AgentPaneNavigation.decision(for: artifact, source: pane, userClicked: false, mainFrame: false,
                                                 sourceFrameURL: pane.pageURL, targetFrameURL: target) == .allow)
        }
    }

    @Test func artifactResponsesEnforceOpaqueSandboxAndPaneAncestors() throws {
        let headers = AgentPaneRenderFrame.headers(length: 1, artifact: true)
        let policy = try #require(headers["Content-Security-Policy"])
        let directives = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(directives.contains("sandbox allow-scripts"))
        #expect(directives.contains("frame-ancestors cmux-agent://pane"))
        #expect(!policy.contains("allow-same-origin"))
        #expect(!policy.contains("127.0.0.1"))
        let render = try #require(AgentPaneRenderFrame.headers(length: 1)["Content-Security-Policy"])
        #expect(render.contains("https://cdn.jsdelivr.net"))
        #expect(render.contains("'unsafe-eval'"))
        #expect(!render.contains("sandbox"))
    }
}
