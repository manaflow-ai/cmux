import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxLiveSessionTests {
    @Test func encodedRegistryJSONCarriesAttachIdentityAndAgentState() throws {
        let session = CmxLiveSession(
            id: "workspace-1",
            workspaceID: "workspace-1",
            terminalID: "terminal-1",
            agentSessionID: "agent-session-1",
            title: "Ship handoff",
            agent: "codex",
            status: .needsInput,
            lastActivityAt: 1_800_000_000
        )

        let data = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["workspaceID"] as? String == "workspace-1")
        #expect(object["terminalID"] as? String == "terminal-1")
        #expect(object["agentSessionID"] as? String == "agent-session-1")
        #expect(object["status"] as? String == "needs_input")
        #expect(object["lastActivityAt"] as? Double == 1_800_000_000)
    }

    @Test func codableRoundTripPreservesStatus() throws {
        let original = CmxLiveSession(
            id: "workspace-2",
            workspaceID: "workspace-2",
            title: "Quiet shell",
            status: .idle,
            lastActivityAt: 1_800_000_010
        )

        let decoded = try JSONDecoder().decode(CmxLiveSession.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
