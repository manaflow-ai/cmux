import CmuxConversation
import Foundation
import Testing

struct ConversationReducerTests {
    let reducer = ConversationReducer()

    func env(_ order: UInt64, _ event: ConversationEvent) -> ConversationEnvelope {
        ConversationEnvelope(cursor: ConversationCursor(order: order), timestamp: order * 1000, event: event)
    }

    func ids(_ s: ConversationState) -> [String] { s.items.map(\.id) }

    func delivery(_ s: ConversationState, _ id: String) -> DeliveryState? {
        guard let item = s.items.first(where: { $0.id == id }), case let .message(m) = item.kind else { return nil }
        return m.delivery
    }

    @Test func streamedTextAndReasoningCollectIntoOneRowEach() {
        var s = ConversationState()
        reducer.apply([
            env(1, .userMessage(clientMessageID: ClientMessageID("a"), text: "hi", attachments: [], steer: false)),
            env(2, .reasoningText("thinking ")),
            env(3, .reasoningText("hard")),
            env(4, .assistantText("hello ")),
            env(5, .assistantText("there")),
        ], to: &s)
        #expect(ids(s) == ["user:a", "reasoning:2", "assistant:4"])
        guard case let .message(m) = s.items[2].kind else { Issue.record("not a message"); return }
        #expect(m.text == "hello there")
        guard case let .reasoning(r) = s.items[1].kind else { Issue.record("not reasoning"); return }
        #expect(r == "thinking hard")
    }

    @Test func duplicatesAreIgnored() {
        var s = ConversationState()
        let e = env(1, .assistantText("x"))
        reducer.apply([e], to: &s)
        reducer.apply([e, e], to: &s)
        guard case let .message(m) = s.items[0].kind else { Issue.record("not a message"); return }
        #expect(m.text == "x")
    }

    @Test func anOlderPageFoldsAsIfItArrivedInOrder() {
        let all: [ConversationEnvelope] = [
            env(1, .userMessage(clientMessageID: ClientMessageID("a"), text: "run tests", attachments: [], steer: false)),
            env(2, .activityStarted(id: "t1", ActivityItem(kind: "execute", title: "cargo test", status: "pending"))),
            env(3, .activityUpdated(id: "t1", status: "completed", title: nil, detail: "ok")),
            env(4, .assistantText("all green")),
        ]
        var inOrder = ConversationState()
        reducer.apply(all, to: &inOrder)

        // The newest page starts mid-turn: an update whose start is older.
        var paged = ConversationState()
        reducer.apply(Array(all[2...]), to: &paged)
        reducer.apply(Array(all[..<2]), to: &paged)
        #expect(paged.items == inOrder.items)
        #expect(ids(paged) == ["user:a", "activity:t1", "assistant:4"])
    }

    @Test func aLocalSendBecomesTheBackendsRowWithoutChangingIdentity() {
        var s = ConversationState()
        reducer.apply([env(1, .turnStarted(clientMessageID: nil))], to: &s)
        let msg = OutgoingMessage(clientMessageID: ClientMessageID("m"), text: "next")
        reducer.applyLocalSend(msg, to: &s)
        #expect(delivery(s, "user:m") == .sending)
        #expect(reducer.unconfirmedSends(in: s).map(\.clientMessageID) == [ClientMessageID("m")])

        reducer.apply([env(2, .userMessageQueued(clientMessageID: ClientMessageID("m"), text: "next", attachments: [], position: 2, held: false))], to: &s)
        #expect(delivery(s, "user:m") == .queued(position: 2))
        #expect(reducer.unconfirmedSends(in: s).isEmpty)

        reducer.apply([env(3, .queueChanged([QueuedPrompt(clientMessageID: ClientMessageID("m"), position: 1)]))], to: &s)
        #expect(delivery(s, "user:m") == .queued(position: 1))

        reducer.apply([env(4, .assistantText("done")), env(5, .userMessage(clientMessageID: ClientMessageID("m"), text: "next", attachments: [], steer: false))], to: &s)
        #expect(delivery(s, "user:m") == .delivered)
        #expect(ids(s).last == "user:m", "the message moves after the turn that ran before it")
        #expect(ids(s).filter { $0 == "user:m" }.count == 1)
    }

    @Test func unconfirmedLocalSendsStayAtTheEndThroughRefolds() {
        var s = ConversationState()
        reducer.apply([env(5, .assistantText("b"))], to: &s)
        reducer.applyLocalSend(OutgoingMessage(clientMessageID: ClientMessageID("x"), text: "hi"), to: &s)
        reducer.apply([env(1, .assistantText("a"))], to: &s) // older page: refold
        #expect(ids(s).last == "user:x")
        #expect(delivery(s, "user:x") == .sending)
    }

    @Test func aDequeuedMessageDisappears() {
        var s = ConversationState()
        reducer.apply([env(1, .userMessageQueued(clientMessageID: ClientMessageID("q"), text: "later", attachments: [], position: 1, held: false))], to: &s)
        reducer.apply([env(2, .userMessageDequeued(clientMessageID: ClientMessageID("q"), text: "later"))], to: &s)
        #expect(s.items.isEmpty)
    }

    @Test func heldUploadsFailAndGoMissing() {
        var s = ConversationState()
        let pdf = ConversationAttachment(uploadID: "u1", name: "a.pdf", mimeType: "application/pdf", size: 100, sha256: String(repeating: "0", count: 64))
        reducer.apply([env(1, .userMessageQueued(clientMessageID: ClientMessageID("f"), text: "read", attachments: [pdf], position: 1, held: true))], to: &s)
        #expect(delivery(s, "user:f") == .uploading)
        reducer.apply([env(2, .attachmentProgress(uploadID: "u1", received: 40))], to: &s)
        #expect(s.attachments["u1"]?.state == .uploading(received: 40))
        reducer.apply([env(3, .userMessageFailed(clientMessageID: ClientMessageID("f"), text: "read", attachments: [pdf], failedUploadIDs: ["u1"]))], to: &s)
        #expect(delivery(s, "user:f") == .failed)
        #expect(s.attachments["u1"]?.state == .failed)
        var gone = pdf
        gone.state = .missing
        reducer.apply([env(4, .attachmentChanged(gone))], to: &s)
        #expect(s.attachments["u1"]?.state == .missing)
    }

    @Test func approvalsResolveInPlace() {
        var s = ConversationState()
        let r = ApprovalRequest(id: "p1", title: "rm -rf build", options: [ApprovalOption(id: "y", label: "Allow", kind: "allow_once")])
        reducer.apply([env(1, .approvalRequested(r))], to: &s)
        #expect(s.pendingApproval?.id == "p1")
        reducer.apply([env(2, .approvalResolved(id: "p1", optionID: "y"))], to: &s)
        #expect(s.pendingApproval == nil)
    }

    @Test func aNewPlanReplacesTheTurnsPlan() {
        var s = ConversationState()
        reducer.apply([
            env(1, .userMessage(clientMessageID: nil, text: "go", attachments: [], steer: false)),
            env(2, .plan([PlanEntry(content: "a", status: "pending")])),
            env(3, .plan([PlanEntry(content: "a", status: "completed")])),
        ], to: &s)
        #expect(ids(s) == ["user:o1", "plan:2"])
        guard case let .plan(entries) = s.items[1].kind else { Issue.record("not a plan"); return }
        #expect(entries.first?.status == "completed")
    }

    @Test func aDeletedConversationStaysDeleted() {
        var s = ConversationState()
        reducer.apply([env(1, .deleted), env(2, .statusChanged(.ready))], to: &s)
        #expect(s.isDeleted)
    }

    @Test func framerSplitsLinesAndRefusesOversizedOnes() throws {
        var framer = LineFramer(maximumLineBytes: 8)
        #expect(try framer.append(Data("ab\ncd".utf8)) == [Data("ab".utf8)])
        #expect(try framer.append(Data("\n\n".utf8)) == [Data("cd".utf8)])
        #expect(throws: LineFramer.LineTooLong.self) { try framer.append(Data("123456789".utf8)) }
    }
}
