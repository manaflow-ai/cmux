import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The render frame a render card shows an agent's HTML in: which URL it is,
/// where it may load, and the policy it is served with.
@MainActor
@Suite struct AgentPaneRenderFrameTests {
    private let frameURL = URL(string: "cmux-agent://render/frame")!
    private var bundled: AgentPaneSource {
        .bundled(URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/agent-pane/index.html"))
    }

    @Test func onlyTheFrameDocumentIsTheFrame() {
        #expect(AgentPaneRenderFrame.isFrame(frameURL))
        #expect(AgentPaneRenderFrame.isFrame(URL(string: "CMUX-AGENT://RENDER/frame")!))
        for text in ["cmux-agent://render/other", "cmux-agent://render/", "cmux-agent://pane/frame",
                     "cmux-agent://render:8/frame", "http://render/frame", "cmux-agent://user@render/frame"] {
            #expect(!AgentPaneRenderFrame.isFrame(URL(string: text)!), "\(text)")
        }
    }

    /// A frame inside the bundled page may load the render frame; the main
    /// frame never shows it, and a dev-server pane, which has no render origin,
    /// does not frame it.
    @Test func onlyAFrameOfTheBundledPaneLoadsIt() throws {
        #expect(AgentPaneNavigation.decision(for: frameURL, source: bundled, userClicked: false, mainFrame: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: frameURL, source: bundled, userClicked: false, mainFrame: true) == .cancel)
        let other = URL(string: "cmux-agent://render/other")
        #expect(AgentPaneNavigation.decision(for: other, source: bundled, userClicked: false, mainFrame: false) == .cancel)
        let dev = AgentPaneSource.devServer(try #require(URL(string: "http://127.0.0.1:4176/")))
        #expect(AgentPaneNavigation.decision(for: frameURL, source: dev, userClicked: false, mainFrame: false) == .cancel)
    }

    /// The HTML may run script but reaches nothing: no connection, frame, form
    /// or remote image, and nothing of the pane's origin.
    @Test func thePolicyAllowsScriptButNoConnection() {
        let directives = Dictionary(
            uniqueKeysWithValues: AgentPaneRenderFrame.policy.split(separator: ";").map { part in
                let words = part.split(separator: " ").map(String.init)
                return (words[0], Array(words.dropFirst()))
            }
        )
        #expect(directives["default-src"] == ["'none'"])
        #expect(directives["connect-src"] == ["'none'"])
        #expect(directives["frame-src"] == ["'none'"])
        #expect(directives["form-action"] == ["'none'"])
        #expect(directives["img-src"] == ["data:", "blob:"])
        #expect(directives["script-src"]?.contains("'unsafe-inline'") == true)
        #expect(!AgentPaneRenderFrame.policy.contains("'self'"))
        #expect(!AgentPaneRenderFrame.policy.contains("cmux-agent:"))
        let headers = AgentPaneRenderFrame.headers(length: AgentPaneRenderFrame.document.count)
        #expect(headers["Content-Security-Policy"] == AgentPaneRenderFrame.policy)
        #expect(headers["Content-Type"] == "text/html; charset=utf-8")
    }

    /// The document asks its parent for the HTML and takes it only from there.
    @Test func theDocumentTakesTheHTMLOnlyFromItsParent() throws {
        let text = try #require(String(data: AgentPaneRenderFrame.document, encoding: .utf8))
        #expect(text.contains(#"host.postMessage({ type: "cmux-render-ready" }, "*")"#))
        #expect(text.contains("event.source !== host"))
        #expect(text.contains("cmux-render-size"))
    }
}
