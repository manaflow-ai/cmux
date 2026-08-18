import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch command persistence")
struct AgentLaunchCommandTests {
    @Test("Preserves the rejection reason in the stored snake-case field")
    func rejectedCaptureRoundTripsReason() throws {
        let input = Data(#"""
        {
          "launcher": "codex",
          "arguments": [],
          "source": "rejected",
          "rejection_reason": "launcher-does-not-describe-kind"
        }
        """#.utf8)

        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: input)
        let encoded = try JSONEncoder().encode(command)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["source"] as? String == "rejected")
        #expect(object["rejection_reason"] as? String == "launcher-does-not-describe-kind")
    }
}
