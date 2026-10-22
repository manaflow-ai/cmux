import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileNotifications
import Foundation
import Testing
@testable import CmuxMobileLive

/// A notification reply becomes the same hub call the chat and the Feed make
/// (verify/rich-push.md, "Reply delivery").
@Suite struct PushReplyPlanTests {
    func pending(_ text: String, id: String = "q1") throws -> AgentSessionEvent {
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try #require(AcpmuxRecords(sessionID: "s").permission(id, request: request))
    }

    func question(multi: Bool = false) throws -> AgentSessionEvent {
        try pending(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":\#(multi)},{"question":"Why?","options":[{"label":"Fast"},{"label":"Safe"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#)
    }

    func single() throws -> AgentSessionEvent {
        try pending(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#)
    }

    func permission() throws -> AgentSessionEvent {
        try pending(#"{"toolCall":{"toolCallId":"c1","title":"rm -rf build","kind":"execute"},"options":[{"optionId":"a1","name":"Allow","kind":"allow_once"},{"optionId":"a2","name":"Always","kind":"allow_always"},{"optionId":"r2","name":"Never","kind":"reject_always"},{"optionId":"r1","name":"Reject","kind":"reject_once"}]}"#, id: "p1")
    }

    func reply(_ kind: PushKind, _ action: PushReply.Action) -> PushReply {
        PushReply(mac: "m", kind: kind, sessionId: "s", permissionId: "q1", action: action)
    }

    @Test func aButtonAnswersTheSingleChoiceQuestion() throws {
        guard case .answer(let question, let answer) = try PushReplyPlan.make(reply(.question, .option(1)), pending: single()) else {
            Issue.record("not an answer")
            return
        }
        let reply = try question.reply(answer)
        #expect(reply.answers == .object(["Which?": .string("B")]))
    }

    @Test func theFormAnswersEveryQuestionWithMultiSelectAndOther() throws {
        let action = PushReply.Action.answers(selected: [["A", "B"], []], other: ["", "both"])
        guard case .answer(let question, let answer) = try PushReplyPlan.make(reply(.question, action), pending: question(multi: true)) else {
            Issue.record("not an answer")
            return
        }
        #expect(try question.reply(answer).answers == .object(["Which?": .string("A, B"), "Why?": .string("both")]))
    }

    @Test func anIncompleteFormIsRefusedBeforeAnythingIsSent() throws {
        let action = PushReply.Action.answers(selected: [["A"]], other: [])
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(reply(.question, action), pending: question()) }
    }

    @Test func allowAndDenyUseThePromptsOwnOptions() throws {
        let allow = try PushReplyPlan.make(PushReply(mac: "m", kind: .permission, sessionId: "s", permissionId: "p1", action: .allow(optionID: "a2")), pending: permission())
        #expect(allow == .respond(sessionID: "s", permissionID: "p1", optionID: "a2"))
        // Deny without an id is the one-time reject, never the lasting one.
        let deny = try PushReplyPlan.make(PushReply(mac: "m", kind: .permission, sessionId: "s", permissionId: "p1", action: .deny(optionID: nil)), pending: permission())
        #expect(deny == .respond(sessionID: "s", permissionID: "p1", optionID: "r1"))
        // An allow id the prompt does not offer as an allow is refused (a reject id posing as one too).
        #expect(throws: PushReplyPlan.Refusal.self) {
            try PushReplyPlan.make(PushReply(mac: "m", kind: .permission, sessionId: "s", permissionId: "p1", action: .allow(optionID: "r1")), pending: permission())
        }
    }

    @Test func anAnsweredPromptIsRefused() {
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(reply(.question, .option(0)), pending: nil) }
    }

    @Test func textRepliesPromptTheSessionOnceOrReachChief() throws {
        let r = reply(.completed, .text("go on", attachments: ["a.png"]))
        #expect(try PushReplyPlan.make(r, pending: nil) == .prompt(sessionID: "s", text: "go on", attachments: ["a.png"], promptID: r.id.uuidString.lowercased()))
        #expect(try PushReplyPlan.make(reply(.chief, .text("hi", attachments: [])), pending: nil) == .chief(text: "hi", attachments: []))
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(reply(.terminal, .text("ls", attachments: [])), pending: nil) }
    }
}

@MainActor @Suite struct PushSnapshotsTests {
    @Test func promptsThenRepliesNewestLast() {
        var a = AgentTurn(id: "1", prompt: "fix it", promptAt: Date())
        a.items = [.message(id: "m1", markdown: "done"), .thought(id: "t", text: "hmm")]
        var b = AgentTurn(id: "2", prompt: "ship", promptAt: Date())
        b.status = .failed
        b.errorText = "rate limited"
        let messages = PushSnapshots.messages([a, b])
        #expect(messages.map(\.text) == ["fix it", "done", "ship", "rate limited"])
        #expect(messages.map(\.role) == [.user, .agent, .user, .system])
    }
}
