import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentRuntimeSessionKey")
struct AgentRuntimeSessionKeyTests {
    @Test("Round trips dotted agent identifiers without guessing a prefix")
    func roundTripsDottedAgentIdentifier() throws {
        let expected = AgentRuntimeSessionKey(
            statusKey: "acme.agent",
            sessionID: "session.with/unicode-日本語"
        )

        let decoded = try #require(AgentRuntimeSessionKey(rawValue: expected.rawValue))

        #expect(decoded == expected)
        #expect(expected.rawValue.hasPrefix("acme.agent."))
        #expect(!expected.rawValue.contains("session.with"))
        #expect(expected.compatibleRawValues == [
            expected.rawValue,
            "acme.agent.session.with/unicode-日本語",
        ])
    }

    @Test("Rejects legacy and malformed keys")
    func rejectsLegacyAndMalformedKeys() {
        #expect(AgentRuntimeSessionKey(rawValue: "acme.agent.session-a") == nil)
        #expect(AgentRuntimeSessionKey(rawValue: "acme.agent.~cmux-session-v1~.") == nil)
        #expect(AgentRuntimeSessionKey(rawValue: ".~cmux-session-v1~.c2Vzc2lvbi1h") == nil)
        #expect(AgentRuntimeSessionKey(rawValue: "acme.agent.~cmux-session-v1~.not+url-safe") == nil)
    }

    @Test(
        "Omits legacy aliases that cannot be sent as one protocol token",
        arguments: [
            "session with spaces",
            "session\twith-tab",
            "session\nclear_agent_pid victim",
            "session\u{0000}suffix",
        ]
    )
    func omitsUnsafeLegacyAliases(sessionID: String) {
        let key = AgentRuntimeSessionKey(
            statusKey: "acme.agent",
            sessionID: sessionID
        )

        #expect(key.compatibleRawValues == [key.rawValue])
    }

    @Test("Validates inherited runtime generations")
    func validatesInheritedRuntimeGenerations() {
        let key = AgentRuntimeSessionKey.runtimeGenerationEnvironmentKey

        #expect(AgentRuntimeSessionKey.inheritedRuntimeGeneration(from: [key: "123.5"]) == 123.5)
        #expect(AgentRuntimeSessionKey.inheritedRuntimeGeneration(from: [key: "0"]) == nil)
        #expect(AgentRuntimeSessionKey.inheritedRuntimeGeneration(from: [key: "nan"]) == nil)
        #expect(AgentRuntimeSessionKey.inheritedRuntimeGeneration(from: [key: "invalid"]) == nil)
    }
}
