import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every `transport.intent_invalid` the pane host answers names its method, rule and cause in the
/// app log (`agent-pane.transport`). The page shows only "Something went wrong, so that didn't go
/// through.", and before this only the params rule logged why; the answers rule, a gesture ticket
/// with other `_meta` and a gesture intent that failed to parse logged nothing. A cause names
/// fields and bounds, never a value.
@Suite
struct AgentPaneRefusalLogTests {
    @Test func theLineKeepsTheParamsRuleFormatAndNamesTheRule() {
        let line = AgentPaneRefusalLog.line(.paramsRule, method: "_acpmux/attach", session: "s",
                                            cause: #"unknown param "pinned""#)
        #expect(line == #"agent pane params rule refused method=_acpmux/attach session=s rule=params_rule cause=unknown param "pinned""#)
        #expect(AgentPaneRefusalLog.line(.gestureParse, method: nil, session: nil, cause: "no params")
            == "agent pane gesture parse refused method=- session=none rule=gesture_parse cause=no params")
    }

    @Test func everyRuleHasItsOwnName() {
        let names = AgentPaneRefusalLog.Rule.allCases.map(\.rawValue)
        #expect(Set(names) == ["params_rule", "answers_rule", "gesture_meta", "gesture_parse"])
    }

    @Test func fieldNamesAreSortedAndBounded() {
        #expect(AgentPaneRefusalLog.names(["b", "a"]) == "[a, b]")
        let many = (0..<10).map { "k\($0)" }
        #expect(AgentPaneRefusalLog.names(many) == "[k0, k1, k2, k3, k4, k5, k6, k7, +2]")
        let long = String(repeating: "x", count: 100)
        #expect(AgentPaneRefusalLog.names([long]) == "[" + String(repeating: "x", count: 64) + "…]")
    }

    @Test func aTicketWithOtherMetaNamesThoseKeysFromThePagesOwnFrame() {
        let ticket = AcpmuxPaneMethods.gestureTicketKey
        let prompt: [String: Any] = ["method": "session/prompt", "params": [
            "sessionId": "s", "_meta": [ticket: "t", "acpmux": ["promptId": "p"], "zeta": 1, "alpha": "secret"],
        ]]
        #expect(AcpmuxPaneMethods.takeGestureTicket(prompt).otherMeta)
        #expect(AcpmuxPaneMethods.otherMetaKeys(prompt) == ["alpha", "zeta"])
        let mode: [String: Any] = ["method": "session/set_mode", "params": ["_meta": [ticket: "t", "acpmux": [:]]]]
        #expect(AcpmuxPaneMethods.otherMetaKeys(mode) == ["acpmux"])
    }

    @Test func anAnswerToNoPendingQuestionSaysSoWithoutItsText() {
        let frame: [String: Any] = ["method": "_acpmux/permission_respond", "params": [
            "sessionId": "s", "permissionId": "p", "optionId": "o", "answers": ["Which color?": "secret answer"],
        ]]
        let cause = AcpmuxPaneMethods.answersRuleViolation(frame, options: AcpmuxPermissionOptions())
        #expect(cause == "answers for no pending question")
        #expect(AcpmuxPaneMethods.breaksAnswersRule(frame, options: AcpmuxPermissionOptions()))
        #expect(cause?.contains("secret") == false)
    }

    @Test func aFrameThatKeepsTheAnswersRuleHasNoCause() {
        let frame: [String: Any] = ["method": "_acpmux/permission_respond", "params": [
            "sessionId": "s", "permissionId": "p", "optionId": "o",
        ]]
        #expect(AcpmuxPaneMethods.answersRuleViolation(frame, options: AcpmuxPermissionOptions()) == nil)
    }

    @Test func aGestureIntentWithAnUnknownParamNamesTheKeyNotTheValue() {
        let params: [String: Any] = ["intent": ["method": "session/set_mode",
                                                "params": ["modeId": "plan", "extra": "secret value"]]]
        #expect(AgentPaneGestureIntent(gestureParams: params) == nil)
        let cause = AgentPaneGestureIntent.refusal(gestureParams: params)
        #expect(cause == "intent params unknown [extra]")
        #expect(AgentPaneGestureIntent.method(gestureParams: params) == "session/set_mode")
    }

    @Test func eachGestureContractBreakHasItsCause() {
        #expect(AgentPaneGestureIntent.refusal(gestureParams: nil) == "no params")
        #expect(AgentPaneGestureIntent.refusal(gestureParams: ["intent": [:], "x": 1]) == "params keys [intent, x] are not [intent]")
        #expect(AgentPaneGestureIntent.refusal(gestureParams: ["intent": ["method": "nope", "params": [:]]])
            == "intent method not one a gesture proves")
        #expect(AgentPaneGestureIntent.refusal(gestureParams: ["intent": ["method": "session/set_mode", "params": [:]]])
            == "intent params missing [modeId]")
        #expect(AgentPaneGestureIntent.refusal(gestureParams: ["intent": ["method": "session/set_mode",
                                                                          "params": ["modeId": ["a": 1]]]])
            == "intent param [modeId] not a scalar")
        #expect(AgentPaneGestureIntent.refusal(gestureParams: ["intent": ["method": "session/set_mode",
                                                                          "params": ["modeId": "plan"]]]) == nil)
    }

    @Test func theTransportGestureRequestCarriesTheRefusal() {
        let request = AgentPaneRequest(body: ["method": "transport.gesture",
                                              "params": ["intent": ["method": "session/set_mode", "params": [String: Any]()]]])
        guard case .transportGesture(nil, let method, let refusal) = request else {
            Issue.record("not a refused transport.gesture: \(String(describing: request))")
            return
        }
        #expect(method == "session/set_mode")
        #expect(refusal == "intent params missing [modeId]")
    }
}
