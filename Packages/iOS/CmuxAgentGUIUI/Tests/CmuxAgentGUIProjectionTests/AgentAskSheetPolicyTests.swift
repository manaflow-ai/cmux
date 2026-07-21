import CmuxAgentReplica
import CmuxAgentWire
import Testing
@testable import CmuxAgentGUIUI

@Suite("Agent ask sheet policy")
struct AgentAskSheetPolicyTests {
    @Test("a different ask clears the prior error")
    func switchingAsk() {
        #expect(AgentAskSheetPolicy.shouldResetError(previousAskID: "old", nextAskID: "new"))
        #expect(!AgentAskSheetPolicy.shouldResetError(previousAskID: "same", nextAskID: "same"))
    }

    @Test("an externally resolved ask dismisses its sheet")
    func resolvedAskDismisses() {
        let active = PendingAsk(
            id: "ask",
            sessionID: AgentSessionID(rawValue: "session"),
            kind: .question,
            promptSummary: "Choose",
            options: ["One"],
            state: .active
        )
        var resolved = active
        resolved = PendingAsk(
            id: active.id,
            sessionID: active.sessionID,
            kind: active.kind,
            promptSummary: active.promptSummary,
            options: active.options,
            state: .answered(choice: 0)
        )
        #expect(!AgentAskSheetPolicy.shouldDismiss(selectedAskID: "ask", asks: [active]))
        #expect(AgentAskSheetPolicy.shouldDismiss(selectedAskID: "ask", asks: [resolved]))
    }
}

@Suite("Agent session interaction capabilities")
struct AgentSessionInteractionCapabilitiesTests {
    @Test("directory tier provides a conservative preflight before the report arrives")
    func tierFallback() {
        #expect(AgentSessionInteractionCapabilities(report: nil, tier: .wrapped) == .init(
            canSteer: true,
            canAnswer: false
        ))
        #expect(AgentSessionInteractionCapabilities(report: nil, tier: .observed) == .init(
            canSteer: false,
            canAnswer: false
        ))
    }

    @Test("the server report is authoritative")
    func reportWins() {
        let report = GuiCapabilitiesResult(
            tier: .observed,
            reasons: [],
            steerable: true,
            answerable: true
        )
        #expect(AgentSessionInteractionCapabilities(report: report, tier: .degraded) == .init(
            canSteer: true,
            canAnswer: true
        ))
    }
}
