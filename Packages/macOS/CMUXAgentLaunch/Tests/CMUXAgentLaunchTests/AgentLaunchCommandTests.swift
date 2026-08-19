import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch command persistence")
struct AgentLaunchCommandTests {
    @Test("Preserves the rejection reason in the stored field")
    func rejectedCaptureRoundTripsReason() throws {
        let input = Data(#"""
        {
          "launcher": "codex",
          "arguments": [],
          "source": "rejected",
          "rejectionReason": "sanitizerRejectedArgv"
        }
        """#.utf8)

        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: input)
        let encoded = try JSONEncoder().encode(command)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["source"] as? String == "rejected")
        #expect(object["rejectionReason"] as? String == "sanitizerRejectedArgv")
    }
}
