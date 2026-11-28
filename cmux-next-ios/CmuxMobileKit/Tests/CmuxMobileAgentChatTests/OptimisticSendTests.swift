import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-22: "i dont wanna see connecting to cosmic-gray... with the spinner, i want it to
/// just work." A message shows the moment it is sent, whether or not the Mac is there yet; only one
/// the Mac never took within ``AgentChatStore/sendDeadline`` says so, quietly, on its own row.
@MainActor
@Suite struct OptimisticSendTests {
    typealias Recorder = PromptResendTests.Recorder

    @Test func aMessageShowsAtOnceAndTheMacsCopyTakesItsPlace() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let sent = try #require(PromptResendTests.prompt(source.sent.last))
        #expect(store.turns.count == 1)
        #expect(store.turns.last?.prompt == "run the tests")
        #expect(store.turns.last?.localSend == .sending)
        store.apply(.userMessage(text: "run the tests", promptId: sent.id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.count == 1, "one bubble, never two")
        #expect(store.turns.last?.id == "t1")
        #expect(store.turns.last?.localSend == nil)
    }

    @Test func aMessageTheMacNeverTookIsMarkedNotSentAndSendsAgainOnATap() async throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.sendDeadlineOverride = .milliseconds(30)
        store.send(prompt: "run the tests")
        let sent = try #require(PromptResendTests.prompt(source.sent.last))
        for _ in 0..<200 where store.turns.last?.localSend != .notSent { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.turns.last?.localSend == .notSent)
        #expect(store.clientError == nil, "never a toast")
        #expect(store.returnedDraft == nil, "the message stays where it was drawn")
        let turnID = try #require(store.turns.last?.id)
        store.sendAgain(turnID: turnID)
        let again = try #require(PromptResendTests.prompt(source.sent.last))
        #expect(again.id == sent.id)
        #expect(again.resend)
        #expect(store.turns.last?.localSend == .sending)
        #expect(store.turns.count == 1)
    }

    @Test func theSourcesUnreachableNoticeMarksTheBubbleNotAToast() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "hi")
        let sent = try #require(PromptResendTests.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "hi", attachments: [], promptID: sent.id, reason: AgentChatStore.unreachableNotice))
        #expect(store.turns.last?.localSend == .notSent)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }

    @Test func aTransientFailureIsNeverAClientError() {
        let store = AgentChatStore(source: Recorder())
        store.apply(.clientError(AgentChatStore.unreachableNotice))
        #expect(store.clientError == nil)
        #expect(store.unreachable)
    }

    @Test func aReplacedStoreHandsItsWaitingMessagesToTheNext() throws {
        let first = Recorder()
        let old = AgentChatStore(source: first)
        old.send(prompt: "one")
        old.send(prompt: "two")
        let waiting = old.waitingMessages
        #expect(waiting.map(\.prompt) == ["one", "two"])
        let next = Recorder()
        let store = AgentChatStore(source: next)
        store.adoptWaiting(waiting)
        #expect(store.turns.map(\.prompt) == ["one", "two"])
        #expect(next.sent.compactMap { PromptResendTests.prompt($0)?.resend } == [true, true])
        #expect(next.sent.compactMap { PromptResendTests.prompt($0)?.id }
            == first.sent.compactMap { PromptResendTests.prompt($0)?.id })
    }
}
