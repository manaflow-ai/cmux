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
            payload: ["error": "transport"]
        ))
    }

    @Test("rejects the OpenAI Trusted Access refusal")
    func rejectsTrustedAccessRefusal() {
        #expect(!proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: """
            ⓘ This content can't be shown

            We take extra caution with cybersecurity requests. If you're a security
            professional, you may be able to apply for Trusted Access.

            Trusted Access: https://openai.com/form/enterprise-trusted-access-for-cyber/
            """,
            payload: nil
        ))
    }

    @Test("rejects ANSI-wrapped structured failure output")
    func rejectsAnsiWrappedFailure() {
        #expect(!proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "\u{001B}[31mHTTP 503\u{001B}[0m service unavailable",
            payload: ["error": "transport"]
        ))
    }

    @Test("accepts a bare HTTP 500 assistant message without failure evidence")
    func acceptsBareHTTPStatusWithoutFailureEvidence() {
        #expect(proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "HTTP 500 Internal Server Error",
            payload: ["session_id": "successful-turn"]
        ))
    }

    @Test("requires a structured failure envelope for ambiguous retry prose")
    func ambiguousRetryProseNeedsFailureEvidence() {
        #expect(proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "Try again later.",
            payload: ["session_id": "successful-turn"]
        ))
        #expect(!proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "Try again later.",
            payload: ["codex_error_info": "server_overloaded"]
        ))
    }

    @Test("does not treat an uncorroborated retry phrase as a stall")
    func acceptsAmbiguousProseWithoutHookEvidence() {
        #expect(proof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: "Try again later.",
            payload: nil
        ))
    }

    @Test("rejects control-only assistant output")
    func rejectsAnsiOnlyOutput() {
        #expect(!proof.provesNormalCompletion(
            provider: "claude",
            assistantMessage: "\u{001B}[2J\u{001B}[H",
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

    @Test("treats explicit success-shaped failure fields as non-failures")
    func acceptsExplicitlyClearFailureFields() {
        for value: Any in ["ok", false, 0] {
            #expect(proof.provesNormalCompletion(
                provider: "codex",
                assistantMessage: "Implemented the requested change.",
                payload: ["error": value]
            ))
        }
    }
}
