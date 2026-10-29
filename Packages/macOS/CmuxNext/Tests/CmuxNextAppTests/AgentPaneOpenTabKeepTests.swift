@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

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
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []
        model.onOpenTab = { opened.append($0) }
        model.transport.gestures.record()  // a run needs the person's click (cx-hnpxh)
        _ = await Self.ask(model, ["kind": "terminal", "text": "codex login", "cwd": "/tmp/project", "run": true, "keep": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "https://opencode.ai/docs", "keep": true])
        _ = await Self.ask(model, ["kind": "browser", "text": "example.com"])
        #expect(opened.map(\.keep) == [true, true, false])
        #expect(opened.first == AgentPaneOpenTab(kind: .terminal, text: "codex login", cwd: "/tmp/project", run: true, keep: true))
    }
}
