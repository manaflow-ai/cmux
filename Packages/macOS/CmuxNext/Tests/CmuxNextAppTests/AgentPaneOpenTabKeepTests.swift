@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The Harnesses page's Sign In and Install… (cx-uj5g8 follow-up): `tab.open` with `keep` asks the
/// host to open the terminal or browser tab beside the page, so a page with no chat yet is not
/// replaced by it. Without `keep` the page's other opens (the New Tab page's rows) replace it as before.
@MainActor
struct AgentPaneOpenTabKeepTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func ask(_ model: AgentPaneModel, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "tab.open", "params": params]))
    }

    @Test func keepReachesTheHostOnlyWhenThePageAsks() async {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []
        model.onOpenTab = { opened.append($0) }
        model.transport.gestures.record()  // a run needs the person's click (cx-hnpxh)
        _ = await Self.ask(model, ["kind": "terminal", "text": "codex login", "cwd": "/tmp/project", "run": true, "keep": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "https://opencode.ai/docs", "keep": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "example.com"])
        #expect(opened.map(\.keep) == [true, true, false])
        #expect(opened.first == AgentPaneOpenTab(kind: .terminal, text: "codex login", cwd: "/tmp/project", run: true, keep: true))
    }

    /// The New Tab page's create buttons send `inPlace`; every other open leaves it off.
    @Test func inPlaceReachesTheHostOnlyWhenThePageAsks() async {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []
        model.onOpenTab = { opened.append($0) }
        _ = await Self.ask(model, ["kind": "terminal", "text": "", "run": false, "inPlace": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "", "inPlace": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "example.com"])
        #expect(opened.map(\.inPlace) == [true, true, false])
    }

    /// Option-Return on the New Tab page sends `beside` for a browser open (a new tab where links go); a plain
    /// Return sends none, so the address navigates the page's tab (Lawrence 2026-11-11). A terminal never takes it.
    @Test func besideReachesTheHostOnlyForABrowserTheTabAsksFor() async {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []
        model.onOpenTab = { opened.append($0) }
        _ = await Self.ask(model, ["kind": "browser", "text": "example.com"])
        _ = await Self.ask(model, ["kind": "browser", "text": "example.com", "beside": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "tides", "search": true, "beside": true])
        _ = await Self.ask(model, ["kind": "terminal", "text": "", "run": false, "beside": true])
        #expect(opened.map(\.beside) == [false, true, true, false])
        #expect(opened.map(\.navigatesInPlace) == [true, false, false, false])
    }
}
