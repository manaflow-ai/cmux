import Foundation
import Testing
@testable import CmuxMobileAgentChat

@MainActor
@Suite struct FailedTurnRetryTests {
    @Test func retryUsesTheDaemonOperationAndWaitsForItsRecord() throws {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        let attachment = AgentAttachment(kind: .file, name: "notes.txt", data: Data("notes".utf8))
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [attachment], at: Date()))
        store.apply(.turnResult(turnId: "t", status: .failed, errorText: "unavailable", at: Date()))
        let turn = try #require(store.turns.last)
        store.retryFailedTurn(turn)
        store.retryFailedTurn(turn)
        #expect(source.sent == [.retryFailedTurn])
        #expect(store.turns == [turn]) // A refused request must not remove the failed input.
        store.apply(.clientError("Disconnected"))
        store.retryFailedTurn(turn)
        #expect(source.sent.count == 2)
        store.apply(.turnRetried(previousTurnID: "t", turnID: "retry"))
        store.apply(.userMessage(text: "Continue", promptId: "p~resume-1", turnId: "retry", attachments: [], at: Date()))
        #expect(store.turns.count == 1)
        #expect(store.turns.last?.prompt == "Read this")
        #expect(store.turns.last?.attachments == [attachment])
        #expect(store.turns.last?.errorText == nil)
        #expect(store.turns.last?.status == .running)
        store.retryFailedTurn(turn) // The stale menu cannot retry another turn.
        #expect(source.sent.count == 2)
    }

    @Test func aLostRetryCanBeSentAgainAfterReconnect() throws {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        let at = Date()
        let attachment = AgentAttachment(kind: .file, name: "notes.txt", data: Data("notes".utf8))
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [attachment], at: at))
        let failure = AgentSessionEvent.turnResult(turnId: "t", status: .failed, errorText: "unavailable", at: at)
        store.apply(failure)
        let turn = try #require(store.turns.last)
        store.retryFailedTurn(turn)
        #expect(source.sent == [.retryFailedTurn])

        // linkDown emits only status. Incremental reattach need not replay the original
        // user message, and a request lost before acceptance has no retry record.
        store.apply(.status(.disconnected))
        store.apply(.batch([failure]))
        store.apply(.status(.idle))
        #expect(store.turns == [turn])
        store.retryFailedTurn(try #require(store.turns.last))
        store.retryFailedTurn(turn)
        #expect(source.sent == [.retryFailedTurn, .retryFailedTurn])
        #expect(store.turns == [turn])
    }

    @Test func aRetryWhoseOriginalIsOutsideLoadedHistoryStillAppears() {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.apply(.turnRetried(previousTurnID: "older", turnID: "retry"))
        store.apply(.userMessage(text: "Continue", promptId: "p~resume-1", turnId: "retry", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["retry"])
    }

    @Test func onlyTheLatestFailedTurnOffersRetry() throws {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "First", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        store.apply(.turnResult(turnId: "t1", status: .failed, errorText: "unavailable", at: Date()))
        let old = try #require(store.turns.last)
        #expect(store.canRetryFailedTurn(old))
        store.apply(.userMessage(text: "Second", promptId: "p2", turnId: "t2", attachments: [], at: Date()))
        let current = try #require(store.turns.last)
        #expect(!store.canRetryFailedTurn(old))
        #expect(!store.canRetryFailedTurn(current))
        store.retryFailedTurn(old)
        #expect(source.sent.isEmpty)
        store.apply(.turnResult(turnId: "t2", status: .failed, errorText: "unavailable", at: Date()))
        #expect(store.canRetryFailedTurn(current))
        store.retryFailedTurn(current)
        #expect(!store.canRetryFailedTurn(current))
        #expect(source.sent == [.retryFailedTurn])
        store.apply(.status(.disconnected))
        #expect(store.canRetryFailedTurn(current))
    }

    @Test(arguments: [false, true])
    func retryOutputStartsANewMessage(withMessageIDs: Bool) throws {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Partial answer", messageId: withMessageIDs ? "old" : nil)))
        store.apply(.turnResult(turnId: "t", status: .failed, errorText: "unavailable", at: Date()))
        store.apply(.batch([
            .turnRetried(previousTurnID: "t", turnID: "retry"),
            .userMessage(text: "Continue", promptId: "p~resume-1", turnId: "retry", attachments: [], at: Date()),
            .update(.agentMessageChunk(text: "New ", messageId: withMessageIDs ? "new" : nil)),
            .update(.agentMessageChunk(text: "answer", messageId: withMessageIDs ? "new" : nil)),
        ]))
        let messages = try #require(store.turns.last).items.compactMap { item -> String? in
            if case .message(_, let text) = item { return text }
            return nil
        }
        #expect(messages == ["Partial answer", "New answer"])
        #expect(store.turns.count == 1)
    }

    @Test func retryThoughtsStartANewItem() throws {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.update(.agentThoughtChunk(text: "Old thought")))
        store.apply(.turnResult(turnId: "t", status: .failed, errorText: "unavailable", at: Date()))
        store.apply(.turnRetried(previousTurnID: "t", turnID: "retry"))
        store.apply(.userMessage(text: "Continue", promptId: "p~resume-1", turnId: "retry", attachments: [], at: Date()))
        store.apply(.update(.agentThoughtChunk(text: "New ")))
        store.apply(.update(.agentThoughtChunk(text: "thought")))
        let thoughts = try #require(store.turns.last).items.compactMap { item -> String? in
            if case .thought(_, let text) = item { return text }
            return nil
        }
        #expect(thoughts == ["Old thought", "New thought"])
    }
}
