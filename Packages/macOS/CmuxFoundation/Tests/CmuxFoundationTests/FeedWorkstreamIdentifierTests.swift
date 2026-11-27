import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct FeedWorkstreamIdentifierTests {
    @Test(arguments: zip(
        ["hermes-agent", "codex", "エージェント"],
        ["session-with-hyphens", "thread/with:punctuation", "セッション-一"]
    ))
    func roundTripsComponentsWithoutDelimiterAmbiguity(
        agentID: String,
        sessionID: String
    ) throws {
        let encoded = try #require(FeedWorkstreamIdentifier(
            agentID: agentID,
            sessionID: sessionID
        ))
        let decoded = try #require(FeedWorkstreamIdentifier(rawValue: encoded.rawValue))

        #expect(decoded.agentID == agentID)
        #expect(decoded.sessionID == sessionID)
    }

    @Test(arguments: [
        "",
        "cmux-feed-v1:",
        "cmux-feed-v1::",
        "cmux-feed-v1:not-base64:also-not-base64",
        "hermes-agent-legacy-session",
    ])
    func rejectsMalformedOrLegacyValues(_ rawValue: String) {
        #expect(FeedWorkstreamIdentifier(rawValue: rawValue) == nil)
    }

    @Test func rejectsEmptyComponents() {
        #expect(FeedWorkstreamIdentifier(agentID: "", sessionID: "session") == nil)
        #expect(FeedWorkstreamIdentifier(agentID: "agent", sessionID: "") == nil)
    }

    @Test(arguments: ["../agent", "agent/name", "agent\\name", "agent\nname"])
    func rejectsUnsafeAgentComponents(_ agentID: String) {
        #expect(FeedWorkstreamIdentifier(agentID: agentID, sessionID: "session") == nil)
    }

    @Test func rejectsUnsafeEncodedAgentComponent() {
        let unsafe = Data("../agent".utf8).base64EncodedString()
        let session = Data("session".utf8).base64EncodedString()
        #expect(FeedWorkstreamIdentifier(rawValue: "cmux-feed-v1:\(unsafe):\(session)") == nil)
    }

    @Test func canonicalizesLegacyIDsWithoutSplittingHyphenatedSessions() throws {
        let legacy = "hermes-agent-session-with-hyphens"
        let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(
            agentID: "hermes-agent",
            rawValue: legacy
        )
        let decoded = try #require(FeedWorkstreamIdentifier(rawValue: canonical))

        #expect(decoded.agentID == "hermes-agent")
        #expect(decoded.sessionID == "session-with-hyphens")
        #expect(
            FeedWorkstreamIdentifier.canonicalizedRawValue(
                agentID: "hermes-agent",
                rawValue: canonical
            ) == canonical
        )
    }

    @Test func canonicalizationLeavesUnrelatedIDsUntouched() {
        #expect(
            FeedWorkstreamIdentifier.canonicalizedRawValue(
                agentID: "claude",
                rawValue: "codex-session"
            ) == "codex-session"
        )
        #expect(
            FeedWorkstreamIdentifier.canonicalizedRawValue(
                agentID: "claude",
                rawValue: "claude-"
            ) == "claude-"
        )
    }
}
