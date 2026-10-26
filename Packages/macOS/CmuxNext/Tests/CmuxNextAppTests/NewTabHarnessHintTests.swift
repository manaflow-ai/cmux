@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextWakeups

/// Integrate a harness, dismissed on a New Tab page, stays dismissed after a relaunch (Leo
/// 2026-10-12: the dismissal sticks). An agent page's own storage ends with the launch, so the page
/// tells the app with its other choices (`newTab.remember` `harnessHint: "dismissed"`) and every
/// later New Tab context carries it back.
@MainActor
struct NewTabHarnessHintTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aDismissedHarnessHintStaysDismissedAfterARelaunch() async throws {
        let suite = "NewTabHarnessHintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        #expect(!memory.harnessHintDismissed)
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), allowsTabConversion: true)
        model.onRememberNewTab = { memory.remember($0) }
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "newTab.remember", "params": ["agent": "codex"]]))
        let reply = await model.respond(to: AgentPaneRequest(body: [
            "method": "newTab.remember", "params": ["harnessHint": "dismissed"],
        ]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")

        // A relaunch: a new memory on the same defaults, and the page context it hands out.
        let relaunched = NewTabChoiceMemory(defaults: defaults)
        var page = AgentPaneNewTab(kind: .agent)
        page.harnessHintDismissed = relaunched.harnessHintDismissed ? true : nil
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        #expect(json["harnessHintDismissed"] as? Bool == true)
        // The dismissal keeps the agent picked before it.
        #expect(relaunched.agent == "codex")
    }
}
