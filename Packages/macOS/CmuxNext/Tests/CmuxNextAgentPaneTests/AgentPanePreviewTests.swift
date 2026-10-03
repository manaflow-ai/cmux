import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A turn's preview card: which pages it may frame and open, how the page asks
/// for a browser tab, and how the model answers.
@MainActor
@Suite struct AgentPanePreviewTests {
    private let pageURL = URL(string: "cmux-agent://pane/index.html")!
    private var bundled: AgentPaneSource {
        .bundled(URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/agent-pane/index.html"))
    }

    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "browser.open", "params": params] as [String: Any])
    }

    @Test func onlyLoopbackWebPagesQualify() {
        for text in ["http://localhost:5173/", "http://127.0.0.1:3000/admin?x=1", "https://localhost:8443/", "http://LOCALHOST:80"] {
            #expect(URL(string: text)?.isAgentPanePreview == true, "\(text)")
        }
        for text in ["https://example.com/", "http://192.168.1.4:3000/", "http://localhost.evil.com/", "file:///etc/hosts",
                     "javascript:alert(1)", "http://user:pass@localhost:3000/", "ws://localhost:3000/", "http://[::1]:3000/"] {
            #expect(URL(string: text)?.isAgentPanePreview != true, "\(text)")
        }
    }

    @Test func theRequestCarriesOnlyALoopbackPage() throws {
        let url = try #require(URL(string: "http://localhost:5173/"))
        #expect(Self.request(["url": "http://localhost:5173/"]) == .openPreview(url))
        #expect(Self.request(["url": "https://example.com/"]) == .unsupported("browser.open"))
        #expect(Self.request(["url": ""]) == .unsupported("browser.open"))
        #expect(Self.request([:]) == .unsupported("browser.open"))
    }

    @Test func theModelOpensThroughTheAppAndReportsARefusal() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:3000/"))
        let model = AgentPaneModel(host: MockAgentPaneHost())
        // No app wired (the quick panel): the page hears that the page could not open.
        var reply = await model.respond(to: .openPreview(url))
        #expect(reply["ok"] as? Bool == false)
        var opened: [URL] = []
        model.onOpenPreview = { url in
            opened.append(url)
            return true
        }
        reply = await model.respond(to: .openPreview(url))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened == [url])
        model.onOpenPreview = { _ in false }
        reply = await model.respond(to: .openPreview(url))
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "open_failed")
    }

    /// A frame inside the page may load a loopback page and follow it there;
    /// it never takes the pane's own page or leaves loopback, and the main
    /// frame's rules are unchanged.
    @Test func aPreviewFrameStaysOnLoopback() {
        let local = URL(string: "http://localhost:5173/")
        #expect(AgentPaneNavigation.decision(for: local, source: bundled, userClicked: false, mainFrame: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: local, source: bundled, userClicked: true, mainFrame: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: "https://example.com/"), source: bundled, userClicked: true, mainFrame: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: pageURL, source: bundled, userClicked: false, mainFrame: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: local, source: bundled, userClicked: false, mainFrame: true) == .cancel)
        #expect(AgentPaneNavigation.decision(for: pageURL, source: bundled, userClicked: false, mainFrame: true) == .allow)
    }

    /// The card's open is the catalog's `openBrowser` on the agent's pane, the
    /// path the tab strip and palette take; a refusal reaches the page.
    @Test func thePreviewOpensThroughOpenBrowser() throws {
        let url = try #require(URL(string: "http://localhost:5173/"))
        let registry = ActionRegistry.standard()
        var asked: [ActionInvocation] = []
        var refuse = false
        // Bound outside #expect: the macro passes its call's arguments through a Sendable closure.
        let bound = registry.bind(.openBrowser, invoke: { invocation in
            asked.append(invocation)
            if refuse { registry.refuse("no pane") }
        })
        #expect(bound)
        #expect(registry.openAgentPreview(url, pane: "pane-1"))
        #expect(asked.last?.target == ActionTargetRef(kind: .pane, id: "pane-1"))
        #expect(asked.last?["url"]?.stringValue == "http://localhost:5173/")
        refuse = true
        #expect(!registry.openAgentPreview(url, pane: "pane-1"))
    }
}
