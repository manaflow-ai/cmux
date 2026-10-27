import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// The long look's history (`PushHistory`) and its buttons: the notified
/// message once, the last four messages up to it, no Reply beside the composer.
@Suite struct PushHistoryTests {
    let reply = "I started an agent and checked that it's running: the build is green and the tests pass."

    func chief(body: String?, tail: [String]) -> PushPayload {
        PushPayload(mac: "m", macName: "Aziz's MacBook Pro", kind: .chief, agent: "Chief", sessionId: "turn-1",
                    conversationId: "home-1", body: body, tail: tail, state: .finished)
    }

    func snapshot(_ texts: [(PushSnapshot.Message.Role, String)]) -> PushSnapshot {
        PushSnapshot(mac: "m", session: PushSnapshot.chiefSession, title: "Chief", avatar: "🦊",
                     messages: texts.map { PushSnapshot.Message(role: $0.0, text: $0.1) })
    }

    /// The bug: the reply's own lines (`tail`) and its `body` were each drawn, the same bubble twice.
    @Test func aChiefReplyWhoseLinesAreItsBodyShowsOnce() {
        let history = PushHistory(payload: chief(body: reply, tail: [reply]), snapshot: nil)
        #expect(history.messages == [.init(role: .agent, text: reply)])
        #expect(history.notifiedIndex == 0)
    }

    @Test func aReplyCutIntoLinesWithoutABodyIsOneMessage() {
        let history = PushHistory(payload: chief(body: nil, tail: ["Done.", "All 31 pass."]), snapshot: nil)
        #expect(history.messages == [.init(role: .agent, text: "Done.\nAll 31 pass.")])
    }

    @Test func theLastFourMessagesEndAtTheNotifiedOne() {
        let saved = snapshot([(.user, "one"), (.agent, "two"), (.user, "three"), (.agent, "four"),
                              (.user, "start an agent please"), (.agent, reply), (.user, "a later message")])
        let history = PushHistory(payload: chief(body: reply, tail: [reply]), snapshot: saved)
        #expect(history.messages.map(\.text) == ["three", "four", "start an agent please", reply])
        #expect(history.notifiedIndex == 3)
    }

    @Test func aReplyTheAppHadNotSavedFollowsTheSavedChat() {
        let saved = snapshot([(.user, "a"), (.agent, "b"), (.user, "c"), (.agent, "d"), (.user, "start an agent please")])
        let history = PushHistory(payload: chief(body: reply, tail: [reply]), snapshot: saved)
        #expect(history.messages.map(\.text) == ["c", "d", "start an agent please", reply])
        #expect(history.messages.count == PushHistory.limit)
    }

    @Test func aSavedMessageCutShorterMatchesAndKeepsTheLongerText() {
        let cut = String(reply.prefix(40)) + "…"
        let history = PushHistory(payload: chief(body: reply, tail: [reply]), snapshot: snapshot([(.user, "go"), (.agent, cut)]))
        #expect(history.messages.map(\.text) == ["go", reply])
    }

    @Test func differentShortMessagesDoNotMatch() {
        #expect(!PushHistory.same("Yes", "Yes, deploy it now to production"))
        #expect(PushHistory.same("Done.  All\npass", "Done. All pass"))
    }

    @Test func aQuestionShowsItsContextAndNoNotifiedBubble() {
        let ask = PushPayload(mac: "m", kind: .question, agent: "Codex", sessionId: "s", title: "Deploy?", tail: ["Built.", "Ready."])
        let history = PushHistory(payload: ask, snapshot: nil)
        #expect(history.messages == [.init(role: .agent, text: "Built.\nReady.")])
        #expect(history.notifiedIndex == nil)
    }

    @Test func anErrorFollowsTheTurnsLastLines() {
        let failed = PushPayload(mac: "m", kind: .failed, agent: "Codex", sessionId: "s", body: "rate limited", tail: ["Working on it"])
        let history = PushHistory(payload: failed, snapshot: nil)
        #expect(history.messages == [.init(role: .agent, text: "Working on it"), .init(role: .system, text: "rate limited")])
    }

    @Test func theComposerReplacesTheReplyButton() throws {
        let payload = chief(body: reply, tail: [reply])
        #expect(PushActions().extensionActions(for: payload, inlineComposer: true) == [])
        let withoutComposer = try #require(PushActions().extensionActions(for: payload, inlineComposer: false))
        #expect(withoutComposer.map(\.identifier) == [PushAction.reply.identifier])
        #expect(withoutComposer.first?.title == "Reply to Chief")
        // A question keeps its option buttons beside the composer.
        let ask = PushPayload(mac: "m", kind: .question, sessionId: "s",
                              questions: [PushQuestion(question: "Deploy?", options: [.init(label: "Yes"), .init(label: "No")])])
        #expect(PushActions().extensionActions(for: ask, inlineComposer: true)?.map(\.title) == ["Yes", "No"])
    }

    @Test func aSnapshotKeepsChiefsAvatarAndAnOlderFileStillReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("push-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PushSnapshotStore(directory: dir)
        store.save(snapshot([(.agent, "hi")]))
        #expect(store.load(mac: "m", session: PushSnapshot.chiefSession)?.avatar == "🦊")
        let old = Data(#"{"mac":"m","session":"s","messages":[{"role":"user","text":"x"}],"updatedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(PushSnapshot.self, from: old)
        #expect(decoded.avatar == nil && decoded.messages.count == 1)
    }
}
