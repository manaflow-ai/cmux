import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Agent hook completion proof")
struct AgentHookCompletionProofTests {
    private let proof = AgentHookCompletionProof()

    @Test("rejects a known provider failure banner")
    func rejectsKnownFailureBanner() {
        #expect(!proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "503 Service Unavailable",
            payload: nil
        ))
    }

    @Test("accepts ordinary assistant text")
    func acceptsOrdinaryText() {
        #expect(proof.provesNormalCompletion(
            provider: "claude",
            assistantMessage: "Implemented the requested change.",
            payload: nil
        ))
    }

    @Test("rejects structured failure evidence")
    func rejectsStructuredFailure() {
        #expect(!proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "Implemented the requested change.",
            payload: ["error": ["code": "transport"]]
        ))
    }
}
