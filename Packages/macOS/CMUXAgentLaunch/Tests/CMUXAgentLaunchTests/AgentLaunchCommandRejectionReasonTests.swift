import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch command rejection reason")
struct AgentLaunchCommandRejectionReasonTests {
    /// A rejected capture must keep the ground it was rejected on. Storing only
    /// `source: "rejected"` records a verdict nobody can act on: the CLI treats
    /// it as no evidence at all and silently downgrades restore.
    @Test func rejectionGroundSurvivesAStoreRoundTrip() throws {
        let stored = """
        {
          "arguments": [],
          "launcher": "codex",
          "source": "rejected",
          "rejectionReason": "sanitizer_rejected_argv",
          "capturedAt": 1
        }
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        #expect(object["source"] as? String == "rejected")
        #expect(object["rejectionReason"] as? String == "sanitizer_rejected_argv")
    }

    /// Records written before the field existed must still decode.
    @Test func recordWithoutARejectionGroundStillDecodes() throws {
        let stored = """
        {"arguments": ["/usr/local/bin/codex"], "source": "process"}
        """
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: Data(stored.utf8))
        #expect(command.arguments == ["/usr/local/bin/codex"])
        #expect(command.source == "process")

        let rewritten = try JSONEncoder().encode(command)
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        #expect(object["rejectionReason"] == nil)
    }
}
