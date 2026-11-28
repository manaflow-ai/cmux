import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Findings on #50262 (Greptile): messages drawn before the Mac has them must not swallow the
/// agent's answers, and one that failed is not lost when its chat's store is replaced.
@MainActor
@Suite struct WaitingMessageReleaseTests {
    typealias Recorder = PromptResendTests.Recorder

    @Test func twoWaitingMessagesDoNotSwallowTheFirstAnswer() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "first")
        store.send(prompt: "second")
        let first = try #require(source.sent.compactMap { PromptResendTests.prompt($0) }.first { $0.text == "first" })
        store.apply(.userMessage(text: "first", promptId: first.id, turnId: "t1", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "the answer", messageId: nil)))
        let recorded = try #require(store.turns.first { $0.id == "t1" })
        #expect(recorded.items.contains { if case .message = $0 { true } else { false } }, "the answer is in the first turn")
        let waiting = try #require(store.turns.last)
        #expect(waiting.localSend == .sending)
        #expect(waiting.items.isEmpty, "the second message's bubble holds nothing of the first answer")
    }

    @Test func aFailedMessageIsCarriedToTheStoreBuiltInItsPlaceWithoutSendingIt() throws {
        let old = Recorder()
        let store = AgentChatStore(source: old)
        store.send(prompt: "lost?")
        let sent = try #require(PromptResendTests.prompt(old.sent.last))
        store.apply(.promptNotSent(text: "lost?", attachments: [], promptID: sent.id, reason: AgentChatStore.unreachableNotice))
        #expect(store.turns.last?.localSend == .notSent)
        let carried = store.waitingMessages
        #expect(carried.count == 1)

        let next = Recorder()
        let replacement = AgentChatStore(source: next)
        replacement.adoptWaiting(carried)
        #expect(replacement.turns.last?.localSend == .notSent, "the bubble and its retry survive")
        #expect(replacement.turns.last?.prompt == "lost?")
        #expect(next.sent.isEmpty, "a failed message is never sent on its own")
        replacement.sendAgain(turnID: try #require(replacement.turns.last?.id))
        #expect(PromptResendTests.prompt(next.sent.last)?.id == sent.id)
    }

    @Test func aNotSentMessageTheMacLaterGotBecomesTheRealMessage() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "late")
        let sent = try #require(PromptResendTests.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "late", attachments: [], promptID: sent.id, reason: AgentChatStore.unreachableNotice))
        #expect(store.turns.last?.localSend == .notSent)
        store.apply(.userMessage(text: "late", promptId: sent.id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.count == 1, "one message, never a Not sent bubble beside the real one")
        #expect(store.turns.last?.id == "t1")
        #expect(store.turns.last?.localSend == nil)
    }

    @Test func aPendingSteerIsCarriedAndResentAsASteer() throws {
        let old = Recorder()
        let store = AgentChatStore(source: old)
        store.apply(.userMessage(text: "first", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t1", at: Date()))
        store.send(prompt: "follow up", steer: true)
        let carried = store.waitingMessages
        #expect(carried.count == 1)
        #expect(carried.first?.steer == true)

        let next = Recorder()
        let replacement = AgentChatStore(source: next)
        replacement.apply(.userMessage(text: "first", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        replacement.apply(.turnStarted(turnId: "t1", at: Date()))
        replacement.adoptWaiting(carried)

        guard case .prompt(let text, _, let steer, let id, let resend) = next.sent.last else {
            Issue.record("the carried steer was not resent")
            return
        }
        #expect(text == "follow up")
        #expect(steer)
        #expect(id == carried.first?.promptID)
        #expect(resend)
    }
}
