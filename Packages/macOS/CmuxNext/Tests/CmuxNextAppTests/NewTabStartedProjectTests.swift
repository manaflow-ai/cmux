@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextWakeups

/// The New Tab default project is the project of the chat the person last picked and started (Leo
/// 2026-10-21: "we dont wanna have stuff constantly get clobbered by agents making projects ... your
/// recently PICKED AND STARTED CHAT... makes more sense"). A page's send tells the app
/// (`newTab.remember` `started`), which keeps it across launches for every later page's context;
/// nothing else writes it.
@MainActor
struct NewTabStartedProjectTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func remember(_ model: AgentPaneModel, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "newTab.remember", "params": params]))
    }

    @Test func aStartedProjectReachesTheNextLaunchsNewTabContext() async throws {
        let suite = "NewTabStartedProjectTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), allowsTabConversion: true)
        model.onRememberNewTab = { memory.remember($0) }
        #expect(memory.startedProject == nil)
        let reply = await Self.remember(model, ["started": "/Users/you/src/atlas"])
        #expect(reply["ok"] as? Bool == true, "\(reply)")

        // Agent and model picks (any folder) leave it; a relative path is never one.
        _ = await Self.remember(model, ["agent": "claude", "model": "claude-opus-5-5", "folder": "/Users/you/briefs"])
        _ = await Self.remember(model, ["started": "briefs/2026-10-20-gui-push"])

        let relaunched = NewTabChoiceMemory(defaults: defaults)
        #expect(relaunched.startedProject == "/Users/you/src/atlas")
        let page = AgentPaneNewTab(kind: .agent).startingIn(relaunched.startedProject)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        #expect(json["startedProject"] as? String == "/Users/you/src/atlas")
    }

    /// A workspace an agent or the CLI makes in a folder never sends `started`: the default stays.
    @Test func aPageWithoutAStartNamesNoStartedProject() throws {
        let suite = "NewTabStartedProjectTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        memory.remember(AgentPaneRememberedPick(agent: "codex", model: "gpt-6-astra", folder: "/Users/you/Projects/lane"))
        #expect(memory.startedProject == nil)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentPaneNewTab(kind: .agent).startingIn(memory.startedProject))) as? [String: Any]
        )
        #expect(json["startedProject"] == nil)
    }
}
