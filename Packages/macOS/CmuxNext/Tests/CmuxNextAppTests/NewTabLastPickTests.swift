@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// The model picked last outlives a relaunch (Leo 2026-10-11, found again on nightly-next
/// 2026-10-12): an agent page's own storage ends with the launch (its web view's store is not
/// persistent), so the page sends each pick to the app (`newTab.remember`) and the next New Tab
/// context carries it back.
@MainActor
struct NewTabLastPickTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func remember(_ model: AgentPaneModel, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "newTab.remember", "params": params]))
    }

    @Test func aPickReachesTheNextLaunchsNewTabContext() async throws {
        let suite = "NewTabLastPickTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.onRememberNewTab = { memory.remember($0) }
        _ = await Self.remember(model, ["agent": "codex", "model": "gpt-6-astra", "folder": "/work/a"])
        _ = await Self.remember(model, ["agent": "claude", "model": "claude-opus-5-5", "folder": "/work/b"])
        // An agent pick alone (the screen's harness row) keeps the models picked before it.
        _ = await Self.remember(model, ["agent": "claude"])

        // A relaunch: a new memory on the same defaults.
        let relaunched = NewTabChoiceMemory(defaults: defaults)
        #expect(relaunched.agent == "claude")
        let page = AgentPaneNewTab(kind: .agent, lastAgent: relaunched.agent, lastPicks: relaunched.picks)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        let picks = try #require(json["lastPicks"] as? [String: Any])
        #expect(picks["global"] as? [String: String] == ["harness": "claude", "model": "claude-opus-5-5"])
        #expect(picks["folders"] as? [[String: String]] == [
            ["folder": "/work/a", "harness": "codex", "model": "gpt-6-astra"],
            ["folder": "/work/b", "harness": "claude", "model": "claude-opus-5-5"],
        ])
    }

    /// Cloud keeps its own pick (agent, model, level), apart from This Mac's (model-picker-local-cloud-state):
    /// a Cloud pick never changes This Mac's last agent or picks, a pick on This Mac never changes Cloud's,
    /// both outlive a relaunch, and `newTab.cloudPick` answers Cloud's for a chat page with no New Tab context.
    @Test func cloudKeepsItsOwnPickApartFromThisMacs() async throws {
        let suite = "NewTabLastPickTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.onRememberNewTab = { memory.remember($0) }
        model.cloudAgentPick = { memory.cloudAgent }
        model.cloudPick = { nil }
        _ = await Self.remember(model, ["agent": "claude", "model": "claude-opus-5-5", "folder": "/work/a"])
        _ = await Self.remember(model, ["side": "cloud", "agent": "codex", "model": "gpt-6.1-sol", "effort": "high"])
        // This Mac's pick is as it was.
        #expect(memory.agent == "claude")
        #expect(memory.picks?.global == .init(harness: "claude", model: "claude-opus-5-5"))
        #expect(memory.cloudAgent == .init(harness: "codex", model: "gpt-6.1-sol", effort: "high"))
        // A later pick on This Mac leaves Cloud's.
        _ = await Self.remember(model, ["agent": "claude", "model": "claude-sonnet-5"])
        #expect(memory.cloudAgent == .init(harness: "codex", model: "gpt-6.1-sol", effort: "high"))
        // A Cloud pick with no agent is no pick.
        _ = await Self.remember(model, ["side": "cloud", "model": "gpt-6"])
        #expect(memory.cloudAgent?.model == "gpt-6.1-sol")

        let relaunched = NewTabChoiceMemory(defaults: defaults)
        #expect(relaunched.picks?.global == .init(harness: "claude", model: "claude-sonnet-5"))
        #expect(relaunched.cloudAgent == .init(harness: "codex", model: "gpt-6.1-sol", effort: "high"))
        let page = AgentPaneNewTab(kind: .agent, lastAgent: relaunched.agent, lastPicks: relaunched.picks)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        let picks = try #require(json["lastPicks"] as? [String: Any])
        #expect(picks["cloud"] as? [String: String] == ["harness": "codex", "model": "gpt-6.1-sol", "effort": "high"])

        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "newTab.cloudPick", "params": [String: Any]()]))
        let value = try #require(reply["value"] as? [String: Any])
        let agent = try #require(value["cloudAgent"] as? [String: String])
        #expect(agent == ["harness": "codex", "model": "gpt-6.1-sol", "effort": "high"])
    }

    /// An older blob with no Cloud pick still reads, with none.
    @Test func anOlderPicksBlobReadsWithNoCloudPick() throws {
        let old = #"{"global":{"harness":"claude","model":"claude-opus-5-5"},"folders":[]}"#
        let picks = try JSONDecoder().decode(AgentPaneLastPicks.self, from: Data(old.utf8))
        #expect(picks.global == .init(harness: "claude", model: "claude-opus-5-5"))
        #expect(picks.cloud == nil)
    }

    /// Every harness pick is the next New Tab's: one on the agent's own default model and one that
    /// names no model replace an older harness and model picked before them (a subrouter Claude
    /// profile came back as plain Claude Code on Cmd-N).
    @Test func aDefaultOrModellessHarnessPickReplacesTheOlderPick() throws {
        let suite = "NewTabLastPickTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        memory.remember(AgentPaneRememberedPick(agent: "claude", model: "claude-opus-5-5", folder: "/work/a"))
        memory.remember(AgentPaneRememberedPick(agent: "claude-sr-internal", model: "default", folder: "/work/a"))
        #expect(memory.picks?.global == .init(harness: "claude-sr-internal", model: "default"))
        #expect(memory.picks?.folders.last == .init(folder: "/work/a", harness: "claude-sr-internal", model: "default"))

        memory.remember(AgentPaneRememberedPick(agent: "claude", model: "claude-opus-5-5"))
        memory.remember(AgentPaneRememberedPick(agent: "codex"))
        #expect(memory.agent == "codex")
        #expect(memory.picks?.global == .init(harness: "codex", model: "default"))
        // An agent pick naming no model keeps the last pick's model while it is on that agent.
        memory.remember(AgentPaneRememberedPick(agent: "claude-sr-internal", model: "claude-opus-5-5", folder: "/work/a"))
        memory.remember(AgentPaneRememberedPick(agent: "claude-sr-internal", folder: "/work/a"))
        #expect(memory.picks?.global == .init(harness: "claude-sr-internal", model: "claude-opus-5-5"))
    }
}

/// The iPhone host follows the last picks (``NewTabChoiceMemory`` is observable through its
/// revision), so a pick made on this Mac reaches acpmux and a phone's New Agent Chat.
@MainActor
struct NewTabChoiceMemoryObservationTests {
    @Test func aRememberedPickNotifiesAnObserverOfThePicks() throws {
        let suite = "NewTabChoiceMemoryObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = memory.picks
            _ = memory.agent
        } onChange: {
            changed = true
        }
        memory.remember(AgentPaneRememberedPick(agent: "codex", model: "gpt-5.5", folder: "/work/a"))
        #expect(changed)
        #expect(memory.picks?.global == .init(harness: "codex", model: "gpt-5.5"))
    }
}
