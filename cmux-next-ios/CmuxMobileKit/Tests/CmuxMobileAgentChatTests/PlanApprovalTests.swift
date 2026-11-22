@testable import CmuxMobileAgentChat
import Foundation
import Testing

/// A plan approval (Claude Code's ExitPlanMode, Grok's and Cursor's plan modes) carries its plan, so
/// the phone's permission card renders it and names its answers as the Mac pane's plan card does
/// (Leo, 2026-11-05: "i like these plans too... i want us to be able to render it in ours").
@Suite struct PlanApprovalTests {
    static let plan = "## Retry uploads\n\n1. Add `withRetry`\n2. Wrap `uploadChunk`"

    static func call(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func claudeExitPlanModeCarriesItsPlan() throws {
        let call = try Self.call(#"{"toolCallId":"t","title":"Approve plan","kind":"other","rawInput":{"plan":"  ## Retry uploads\n\n1. Add `withRetry`\n2. Wrap `uploadChunk`\n"},"_meta":{"claude":{"tool":"ExitPlanMode"}}}"#)
        #expect(ACPPermissionRequest.plan(toolCall: call) == Self.plan)
    }

    @Test func switchModeAskCarriesItsPlanFromInputOrContent() throws {
        let input = try Self.call(#"{"toolCallId":"t","title":"Ready to code?","kind":"switch_mode","rawInput":{"plan":"Do it"}}"#)
        #expect(ACPPermissionRequest.plan(toolCall: input) == "Do it")
        let content = try Self.call(#"{"toolCallId":"t","title":"Ready to code?","kind":"switch_mode","content":[{"type":"content","content":{"type":"text","text":"Do it"}}]}"#)
        #expect(ACPPermissionRequest.plan(toolCall: content) == "Do it")
    }

    @Test func aPlanAcpmuxAttachedIsReadFromAnyAsk() throws {
        let call = try Self.call(#"{"toolCallId":"t","title":"Requesting plan approval","kind":"other","_meta":{"acpmux":{"plan":{"markdown":"Do it"}}}}"#)
        #expect(ACPPermissionRequest.plan(toolCall: call) == "Do it")
    }

    @Test func otherAsksCarryNoPlan() throws {
        let edit = try Self.call(#"{"toolCallId":"t","title":"Write","kind":"edit","rawInput":{"plan":"x"}}"#)
        #expect(ACPPermissionRequest.plan(toolCall: edit) == nil)
        let blank = try Self.call(#"{"toolCallId":"t","title":"Ready to code?","kind":"switch_mode","rawInput":{"plan":"  "}}"#)
        #expect(ACPPermissionRequest.plan(toolCall: blank) == nil)
    }

    @Test func planAnswersReadApprovePlanAndKeepPlanning() throws {
        let toolCall = try JSONDecoder().decode(ACPToolCall.self, from: Data(#"{"toolCallId":"t","title":"Approve plan","kind":"other"}"#.utf8))
        let allow = ACPPermissionOption(id: "allow_once", name: "Allow", kind: .allowOnce)
        let reject = ACPPermissionOption(id: "reject_once", name: "Reject", kind: .rejectOnce)
        let planAsk = ACPPermissionRequest(id: "p", toolCall: toolCall, options: [allow, reject], plan: Self.plan)
        #expect(planAsk.phoneOptions.map(planAsk.label(for:)) == ["Approve plan", "Keep planning"])
        let plain = ACPPermissionRequest(id: "q", toolCall: toolCall, options: [allow, reject])
        #expect(plain.phoneOptions.map(plain.label(for:)) == ["Allow once", "Deny"])
    }
}
