import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `newTab.submit` with an agent: the chat it opens starts on that harness.
@Suite struct AgentPaneSeedHarnessTests {
    @Test func theSeedsHarnessReachesTheHandshake() async throws {
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "/src", prompt: "fix it", harness: "codex"))
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: seed)
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["harness"] as? String == "codex")
        #expect(value["prompt"] as? String == "fix it")
    }
}

