import CmuxAgentQuestion
import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileChief

/// Answering Chief's questions from the phone: the order of states, and the
/// signed `question.answer` the Mac receives.
@Suite struct ChiefAnswerFlowTests {
    @Test func sentOnlyAfterTheMacStoredIt() {
        var flow = ChiefAnswerFlow()
        #expect(flow.statusText == nil)
        let began1 = flow.begin()
        #expect(began1)
        #expect(flow.state == .waitingForApproval)
        #expect(flow.statusText == "Waiting for Face ID…")
        // A second Answer while Face ID is up does nothing.
        let began2 = flow.begin()
        #expect(!began2)
        flow.approved()
        #expect(flow.state == .sending)
        #expect(flow.statusText == "Sending…")
        flow.stored()
        #expect(flow.state == .sent)
        // Nothing after sent changes it; it cannot be answered again.
        flow.failed(ChiefApprovalCancelled())
        #expect(flow.state == .sent)
        let began3 = flow.begin()
        #expect(!began3)
    }

    @Test func storedNeverSkipsAnAnswer() {
        var flow = ChiefAnswerFlow()
        flow.stored()
        #expect(flow.state == .idle)
        flow.approved()
        #expect(flow.state == .idle)
    }

    @Test func failuresSayWhyAndAllowAnotherTry() {
        var flow = ChiefAnswerFlow()
        _ = flow.begin()
        flow.failed(ChiefApprovalCancelled())
        #expect(flow.state == .failed("Not sent: Face ID was cancelled."))
        #expect(!flow.isBusy)
        let began4 = flow.begin()
        #expect(began4)
        flow.approved()
        flow.failed(ConversationBackendError(code: -32000, message: "conversation_rejected: question_closed"))
        #expect(flow.state == .failed("Chief no longer needs this answer."))
        #expect(ChiefAnswerFlow.text(ChiefApprovalUnavailable()) == "Not sent: this iPhone isn't paired with the Mac yet.")
        #expect(ChiefAnswerFlow.text(ConversationBackendError(code: -32000, message: "forbidden: bad signature"))
            == "Not sent: your Mac didn't accept this iPhone's approval.")
    }

    /// R2-5: a lost reply after sending is "couldn't confirm", never "Not
    /// sent"; Check settles it from the Mac's own state.
    @Test func lostReplyIsUnconfirmedUntilChecked() {
        struct LinkDropped: Error {}
        var flow = ChiefAnswerFlow()
        _ = flow.begin()
        flow.approved()
        flow.failed(LinkDropped())
        #expect(flow.state == .unconfirmed)
        #expect(flow.statusText == "Couldn't confirm. Chief may have it.")
        // No second answer on top of one the Mac may have.
        let again = flow.begin()
        #expect(!again)
        let checking = flow.beginCheck()
        #expect(checking)
        #expect(flow.statusText == "Checking with your Mac…")
        flow.stored()
        #expect(flow.state == .sent)

        var pending = ChiefAnswerFlow()
        _ = pending.begin()
        pending.approved()
        pending.failed(LinkDropped())
        _ = pending.beginCheck()
        pending.checkedStillPending()
        #expect(pending.state == .failed("Not sent: your Mac doesn't have this answer. Try again."))

        // Before signing, a failure is truly "Not sent".
        var unsigned = ChiefAnswerFlow()
        _ = unsigned.begin()
        unsigned.failed(LinkDropped())
        #expect(unsigned.state == .failed("Not sent: Chief on your Mac didn't take the answer. Try again."))
        // A refusal the Mac returned after sending is "Not sent" too.
        var refused = ChiefAnswerFlow()
        _ = refused.begin()
        refused.approved()
        refused.failed(ConversationBackendError(code: -32000, message: "conversation_rejected: invalid_answer"))
        #expect(refused.state == .failed("Not sent: the answer doesn't fit the question."))
    }

    @Test func questionPartsAreFoundByAddress() {
        let message: [String: Any] = [
            "id": "msg_9", "seq": 9, "author": "agent_mux",
            "parts": [["type": "text", "text": "Allow it?"],
                      ["type": "question", "harness": "chief", "session": "chief", "state": ["kind": "pending"],
                       "items": [["id": "allow", "prompt": "Allow?", "multi_select": false, "allows_other": false,
                                  "options": [["id": "allow", "label": "Allow"]]]]]],
        ]
        let found = ChiefQuestionFeed.questions(in: message)
        #expect(found.seq == 9)
        #expect(found.questions.map(\.id) == ["msg_9#1"])
        #expect(found.questions.first?.isPending == true)
        #expect(ChiefQuestionAddress("msg_9#1") == ChiefQuestionAddress("msg_9#1"))
        #expect(ChiefQuestionAddress("msg_9#1")?.messageID == "msg_9")
        #expect(ChiefQuestionAddress("msg_9#1")?.partIndex == 1)
        #expect(ChiefQuestionAddress("msg_9") == nil)
        var retracted = message
        retracted["retracted_at"] = "2026-10-14T09:00:00.000Z"
        #expect(ChiefQuestionFeed.questions(in: retracted).questions.isEmpty)
    }
}

/// Signs like `ChiefAnswerSigner` without Face ID, and records what it signed.
final class RecordingSigner: ChiefAnswerSigning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var signed: [(conversation: String, messageID: String, partIndex: Int, answer: JSONValue)] = []

    func approval(conversation: String, messageID: String, partIndex: Int, answer: JSONValue) async throws -> JSONValue {
        lock.withLock { signed.append((conversation, messageID, partIndex, answer)) }
        return .object(["approver": .string("phone-1"), "nonce": .string("n1"), "expiresAt": .number(1_800_000_000),
                        "signature": .string("ab")])
    }
}

@Suite struct ChiefQuestionBackendTests {
    @Test func answersWithTheSignedPayload() async throws {
        let daemon = FakeDaemon()
        let messageID = daemon.seedChiefQuestion()
        let link = MockMacLink { _, request in daemon.respond(request) }
        let backend = try await ChiefDaemonBackend.open(link: link)
        var events = backend.events().makeAsyncIterator()
        guard case .connected? = await events.next() else {
            Issue.record("expected connected")
            return
        }
        _ = try await backend.history(beforeSeq: nil, limit: 50)
        let question = try #require(backend.questionFeed.current.first)
        #expect(question.id == "\(messageID)#1")
        #expect(question.isPending)

        let signer = RecordingSigner()
        let approved = Approved()
        let answer = AgentQuestionAnswer(selections: ["allow": .init(optionIDs: ["allow"])])
        try await backend.answer(question, with: answer, signer: signer) { approved.mark() }

        #expect(approved.count == 1)
        // The signer signed exactly the answer that was sent, for this question.
        let signed = try #require(signer.signed.first)
        #expect(signed.conversation == "conv_chief")
        #expect(signed.messageID == messageID)
        #expect(signed.partIndex == 1)
        let expected: JSONValue = .object(["selections": .object(["allow": .object(["option_ids": .array([.string("allow")])])])])
        #expect(signed.answer == expected)
        let op = try #require(daemon.ops.last)
        #expect(op["kind"] as? String == "question.answer")
        #expect(op["message_id"] as? String == messageID)
        #expect(op["part_index"] as? Int == 1)
        let sentAnswer = try #require(op["answer"] as? [String: Any])
        #expect(((sentAnswer["selections"] as? [String: Any])?["allow"] as? [String: Any])?["option_ids"] as? [String] == ["allow"])
        #expect(daemon.lastApproval?["signature"] as? String == "ab")
        #expect(daemon.lastApproval?["approver"] as? String == "phone-1")
        // The owner's answered part reaches the feed.
        #expect(backend.questionFeed.current.first?.isPending == false)
        backend.close()
    }

    /// QA 2026-10-27: Chief retracts the message that asked. Before: the
    /// question stayed pending (the bar kept asking; answering failed with
    /// question_closed). Now it leaves the feed with its message.
    @Test func aRetractedQuestionLeavesTheFeed() async throws {
        let daemon = FakeDaemon()
        let messageID = daemon.seedChiefQuestion()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        _ = try await backend.history(beforeSeq: nil, limit: 50)
        #expect(backend.questionFeed.current.first?.isPending == true)
        daemon.queueRetraction(of: messageID)
        // A read (no op, so no rev of its own) lets the queued event through.
        _ = try await backend.history(beforeSeq: nil, limit: 50)
        let deadline = ContinuousClock.now + .seconds(10)
        while !backend.questionFeed.current.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(backend.questionFeed.current.isEmpty)
        backend.close()
    }

    @Test func noSignerSendsNothing() async throws {
        let daemon = FakeDaemon()
        _ = daemon.seedChiefQuestion()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        _ = try await backend.history(beforeSeq: nil, limit: 50)
        let question = try #require(backend.questionFeed.current.first)
        await #expect(throws: ChiefApprovalUnavailable.self) {
            try await backend.answer(question, with: AgentQuestionAnswer(selections: ["allow": .init(optionIDs: ["allow"])]),
                                     signer: nil) {}
        }
        #expect(!daemon.ops.contains { $0["kind"] as? String == "question.answer" })
        backend.close()
    }

    /// `chief-profile-changed` redraws Chief in place: the store hears the
    /// new avatar as a conversation change, without reconnecting.
    @Test func profileEventRedrawsChief() async throws {
        let daemon = FakeDaemon()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        guard case .connected(let info, _, _)? = await events.next() else {
            Issue.record("expected connected")
            return
        }
        #expect(info.participants.first { $0.id == "agent_mux" }?.initials == "C")
        daemon.queue(["event": "chief-profile-changed", "avatar": "🦊"])
        await backend.setTyping(true)
        var changed: ConversationInfo?
        while changed == nil, let event = await events.next() {
            if case .conversationChanged(let info) = event { changed = info }
            if case .connected = event { Issue.record("must not reconnect") }
        }
        #expect(changed?.participants.first { $0.id == "agent_mux" }?.initials == "🦊")
        // R2-6: an event without an `avatar` key leaves Chief as drawn (a
        // reset would surface "C" before "AB"); the next explicit one applies.
        daemon.queue(["event": "chief-profile-changed"])
        daemon.queue(["event": "chief-profile-changed", "avatar": "AB"])
        await backend.setTyping(false)
        changed = nil
        while changed == nil, let event = await events.next() {
            if case .conversationChanged(let info) = event { changed = info }
        }
        #expect(changed?.participants.first { $0.id == "agent_mux" }?.initials == "AB")
        // A picture (null) or a file name draws "C" again.
        daemon.queue(["event": "chief-profile-changed", "avatar": "avatar.png"])
        await backend.setTyping(false)
        changed = nil
        while changed == nil, let event = await events.next() {
            if case .conversationChanged(let info) = event { changed = info }
        }
        #expect(changed?.participants.first { $0.id == "agent_mux" }?.initials == "C")
        backend.close()
    }

    /// R2-5: Check fetches the conversation again; the Mac's answered state
    /// reaches the feed before it returns.
    @Test func recheckReadsTheMacsState() async throws {
        let daemon = FakeDaemon()
        _ = daemon.seedChiefQuestion()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        try await backend.recheckQuestions()
        #expect(backend.questionFeed.current.first?.isPending == true)
        backend.close()
    }
}

final class Approved: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func mark() { lock.withLock { value += 1 } }
}
