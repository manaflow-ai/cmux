import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent hook payload compactor")
struct AgentHookPayloadCompactorTests {
    private let compactor = AgentHookPayloadCompactor()

    @Test("Encoded transport budget selects a compact identity payload")
    func encodedBudgetSelectsCompactIdentity() throws {
        let rawPayload = String(repeating: "\\\"", count: 12 * 1_024)
        let identityPayload = #"{"session_id":"relay-session","turn_id":"relay-turn"}"#
        let selected = compactor.firstFittingPayload(
            in: [rawPayload, identityPayload],
            maximumPayloadBytes: 4 * 1_024,
            maximumEncodedPayloadBytes: 8 * 1_024
        )
        let encoded = try JSONSerialization.data(
            withJSONObject: ["payload": selected],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        #expect(selected == identityPayload)
        #expect(encoded.count <= 8 * 1_024)
    }

    @Test("Raw-fit payloads are preserved exactly")
    func rawFitIsPreserved() {
        let payload = #"{"session_id":"local-session"}"#
        #expect(compactor.firstFittingPayload(
            in: [payload],
            maximumPayloadBytes: 64 * 1_024
        ) == payload)
    }
}
