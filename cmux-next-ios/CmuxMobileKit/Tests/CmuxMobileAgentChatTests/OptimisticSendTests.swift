import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-24 (relayed): "i think we can maybe be more optimistic sometimes" and "i also
/// couldnt cancel out of the send. i need to be able to do that otherwise i cant edit or
/// anything to retry or delete and remove." A sent message draws as sent in the call that sent
/// it, the Mac's record takes its place under the same row, a slow or failed send is a quiet
/// mark on it, and its Cancel frees the composer in the same call, whatever the upload is doing.
@MainActor
@Suite struct OptimisticSendTests {
    /// A source with an outbox the test scripts: what each action answers, and what was asked.
    final class Outbox: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        var asked: [AgentPromptAction] = []
        var answer: (AgentPromptAction) -> AgentPromptActionResult = { _ in .unknown }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
        func promptAction(_ action: AgentPromptAction) -> AgentPromptActionResult {
            asked.append(action)
            return answer(action)
        }
        var lastPrompt: (text: String, id: String, resend: Bool)? {
            guard case .prompt(let text, _, _, let id, let resend)? = sent.last else { return nil }
            return (text, id, resend)
        }
    }

    @Test func theTapDrawsASentBubbleInTheSameCall() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        // No await: the bubble is there in the call that sent it, looking delivered.
        #expect(store.turns.count == 1)
        #expect(store.turns[0].prompt == "run the tests")
        #expect(store.turns[0].sendLook == .sent)
        #expect(store.turns[0].promptRowID == "u-\(AgentChatStore.provisionalTurnID(id))")
        #expect(store.pendingPrompt(id)?.look == .sent)
        // Nothing waits on the Mac: no Stop, no banner, nothing handed back.
        #expect(!store.isRunning)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }

    @Test func theMacsRecordTakesTheBubblesPlaceWithNoDuplicate() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        let rowBefore = store.turns[0].promptRowID
        store.apply(.userMessage(text: "run the tests", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.count == 1, "one bubble, not two")
        #expect(store.turns[0].id == "t1")
        #expect(store.turns[0].promptRowID == rowBefore, "same row: no flicker, no jump")
        #expect(store.turns[0].sendLook == nil)
        #expect(store.pendingPrompts.isEmpty)
        #expect(store.isRunning)
        // Its answer goes into the same turn.
        store.apply(.update(.agentMessageChunk(text: "ok", messageId: "m1")))
        #expect(store.turns.count == 1)
    }

    @Test func aSteerDrawsInTheRunningTurnAndIsReconciledThere() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "first", promptId: "p0", turnId: "t1", attachments: [], at: Date()))
        store.send(prompt: "also this", steer: true)
        let id = try #require(source.lastPrompt?.id)
        #expect(store.turns.count == 1)
        let steers = store.turns[0].items.compactMap { if case .steer(let m) = $0 { m } else { nil } }
        #expect(steers.map(\.promptID) == [id])
        #expect(steers.first?.sendLook == .sent)
        store.apply(.userMessage(text: "also this", promptId: id, turnId: "t1", attachments: [], at: Date()))
        let after = store.turns[0].items.compactMap { if case .steer(let m) = $0 { m } else { nil } }
        #expect(after.count == 1, "one steer, not two")
        #expect(after.first?.sendLook == nil)
        #expect(store.pendingPrompts.isEmpty)
    }

    @Test func aSteerThatRunsAsItsOwnTurnKeepsItsRow() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "first", promptId: "p0", turnId: "t1", attachments: [], at: Date()))
        store.send(prompt: "also this", steer: true)
        let id = try #require(source.lastPrompt?.id)
        // The turn ended before the agent read it: it runs as the next turn (acpmux steer_end).
        store.apply(.turnResult(turnId: "t1", status: .completed, errorText: nil, at: Date()))
        store.apply(.userMessage(text: "also this", promptId: id, turnId: "t2", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1", "t2"])
        #expect(store.turns[1].promptRowID == "st-\(id)")
        #expect(!store.turns[0].items.contains { if case .steer = $0 { true } else { false } })
    }

    @Test func aRetryingSendIsAQuietMarkThatGoesOnceItGetsOut() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.apply(.promptLook(promptID: id, look: .retrying))
        #expect(store.turns[0].sendLook == .retrying)
        #expect(store.clientError == nil)
        store.apply(.promptLook(promptID: id, look: .sent))
        #expect(store.turns[0].sendLook == .sent)
    }

    @Test func aFailedSendStaysAsAQuietMarkNotABannerOrDraft() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        let rowBefore = store.turns[0].promptRowID
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: id, reason: "Not sent: m was unreachable"))
        #expect(store.turns.count == 1)
        #expect(store.turns[0].sendLook == .failed)
        #expect(store.turns[0].promptRowID == rowBefore)
        #expect(store.pendingPrompt(id)?.reason == "Not sent: m was unreachable")
        #expect(store.clientError == nil, "no alert")
        #expect(store.returnedDraft == nil, "the composer is not refilled")
    }

    @Test func theFullAccessNoticeStillShows() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "keep going")
        let id = try #require(source.lastPrompt?.id)
        store.apply(.promptNotSent(text: "keep going", attachments: [], promptID: id, reason: AgentChatStore.fullAccessOffPromptNotice))
        #expect(store.clientError == AgentChatStore.fullAccessOffPromptNotice)
        #expect(store.turns.first?.sendLook == .failed)
    }

    @Test func cancelOfAnUnwrittenSendFreesTheComposerInTheSameCall() throws {
        let source = Outbox()
        source.answer = { if case .cancel = $0 { .returned } else { .unknown } }
        let store = AgentChatStore(source: source)
        let file = AgentAttachment(kind: .file, name: "clip.mov", data: Data(count: 4096))
        store.send(prompt: "look at this", attachments: [file])
        let id = try #require(source.lastPrompt?.id)
        // Mid-upload (the source never said it was uploaded): Cancel.
        store.cancelPending(id)
        #expect(source.asked == [.cancel(promptID: id)])
        #expect(store.turns.isEmpty, "the bubble goes")
        #expect(store.pendingPrompts.isEmpty)
        #expect(store.returnedDraft?.text == "look at this")
        #expect(store.returnedDraft?.attachments == [file])
    }

    @Test func cancelOfAWrittenSendWaitsForTheMac() throws {
        let source = Outbox()
        source.answer = { if case .cancel = $0 { .removingOnMac } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.cancelPending(id)
        #expect(store.turns.count == 1)
        #expect(store.returnedDraft == nil)
        store.apply(.promptRemoved(promptID: id, removed: true))
        #expect(store.turns.isEmpty)
        #expect(store.returnedDraft?.text == "run the tests")
    }

    @Test func cancelTooLateLeavesTheMacsRecord() throws {
        let source = Outbox()
        source.answer = { if case .cancel = $0 { .removingOnMac } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.cancelPending(id)
        store.apply(.promptRemoved(promptID: id, removed: false))
        store.apply(.userMessage(text: "run the tests", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1"])
        #expect(store.returnedDraft == nil)
    }

    @Test func deleteRemovesWithoutRefillingTheComposer() throws {
        let source = Outbox()
        source.answer = { if case .delete = $0 { .returned } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.deletePending(id)
        #expect(store.turns.isEmpty)
        #expect(store.returnedDraft == nil)
    }

    @Test func cancelOfAFailedSendGivesItBack() throws {
        let source = Outbox() // the outbox gave it up: it holds it no more
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: id, reason: "down"))
        store.cancelPending(id)
        #expect(source.asked == [.delete(promptID: id)], "its failed look is forgotten")
        #expect(store.turns.isEmpty)
        #expect(store.returnedDraft?.text == "run the tests")
    }

    @Test func retryNowOfAFailedSendGoesUnderItsID() throws {
        let source = Outbox()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(source.lastPrompt)
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "down"))
        store.retryPending(first.id)
        let again = try #require(source.lastPrompt)
        #expect(again.id == first.id)
        #expect(again.resend, "acpmux checks its log for one that may have run")
        #expect(store.turns.count == 1)
        #expect(store.turns[0].sendLook == .sent)
    }

    @Test func retryNowOfAWaitingSendAsksTheOutbox() throws {
        let source = Outbox()
        source.answer = { if case .retryNow = $0 { .done } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        store.apply(.promptLook(promptID: id, look: .retrying))
        let sends = source.sent.count
        store.retryPending(id)
        #expect(source.asked == [.retryNow(promptID: id)])
        #expect(source.sent.count == sends, "the outbox sends it, not a second prompt")
        #expect(store.turns[0].sendLook == .sent)
    }

    @Test func editInPlaceKeepsTheRow() throws {
        let source = Outbox()
        source.answer = { if case .edit = $0 { .done } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        let row = store.turns[0].promptRowID
        store.editPending(id, text: "run the unit tests")
        #expect(store.turns[0].prompt == "run the unit tests")
        #expect(store.turns[0].promptRowID == row)
        #expect(store.pendingPrompt(id)?.text == "run the unit tests")
    }

    @Test func editOfAWrittenSendGoesAsANewIDInItsPlace() throws {
        let source = Outbox()
        source.answer = { if case .edit(_, let newID, _) = $0 { .replaced(newPromptID: newID) } else { .unknown } }
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try #require(source.lastPrompt?.id)
        let row = store.turns[0].promptRowID
        store.editPending(id, text: "run the unit tests")
        guard case .edit(_, let newID, _)? = source.asked.last else { Issue.record("no edit asked"); return }
        #expect(store.pendingPrompt(newID)?.text == "run the unit tests")
        #expect(store.pendingPrompt(id) == nil)
        #expect(store.turns[0].promptRowID == row)
        store.apply(.userMessage(text: "run the unit tests", promptId: newID, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1"])
        #expect(store.turns[0].promptRowID == row)
    }
}
