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

    /// Review finding 2: a chat saved before the push holds an older "Done.", not this one.
    @Test func anOlderReplyThatReadsTheSameIsNotTheNotifiedOne() {
        var saved = snapshot([(.user, "build it"), (.agent, "Done."), (.user, "now deploy it")])
        saved.updatedAt = Date(timeIntervalSince1970: 1_000)
        let push = chief(body: "Done.", tail: ["Done."])
        let arrived = Date(timeIntervalSince1970: 2_000)
        let history = PushHistory(payload: push, snapshot: saved, notifiedAt: arrived)
        #expect(history.messages.map(\.text) == ["build it", "Done.", "now deploy it", "Done."])
        #expect(history.notifiedIndex == 3)
        // Saved after it arrived, the chat's own copy is the notified one.
        saved.messages.append(.init(role: .agent, text: "Done."))
        saved.updatedAt = Date(timeIntervalSince1970: 3_000)
        #expect(PushHistory(payload: push, snapshot: saved, notifiedAt: arrived).messages.map(\.text) == ["build it", "Done.", "now deploy it", "Done."])
        // The person's own words never stand for Chief's reply.
        let mine = snapshot([(.user, "Done.")])
        #expect(PushHistory(payload: push, snapshot: mine).messages.map(\.role) == [.user, .agent])
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

    @Test func theReplyFieldReplacesTheReplyButton() throws {
        let payload = chief(body: reply, tail: [reply])
        #expect(PushActions().extensionActions(for: payload, replyField: true) == [])
        let withoutComposer = try #require(PushActions().extensionActions(for: payload, replyField: false))
        #expect(withoutComposer.map(\.identifier) == [PushAction.reply.identifier])
        #expect(withoutComposer.first?.title == "Reply to Chief")
        // A question keeps its option buttons beside the composer.
        let ask = PushPayload(mac: "m", kind: .question, sessionId: "s",
                              questions: [PushQuestion(question: "Deploy?", options: [.init(label: "Yes"), .init(label: "No")])])
        #expect(PushActions().extensionActions(for: ask, replyField: true)?.map(\.title) == ["Yes", "No"])
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

    @Test func whatPlusStagedGoesWithThatNotificationsReplyOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("push-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = PushOutbox(directory: dir)
        try FileManager.default.createDirectory(at: outbox.attachments, withIntermediateDirectories: true)
        for name in ["a1b2c3d4-shot.png", "e5f6a7b8-notes.pdf"] {
            try Data("x".utf8).write(to: outbox.attachments.appendingPathComponent(name))
        }
        try outbox.stage(["a1b2c3d4-shot.png", "e5f6a7b8-notes.pdf", "../escape", "gone.png"], for: "request-1")
        #expect(outbox.takeStaged(for: "other-request").isEmpty)
        #expect(outbox.takeStaged(for: "request-1") == ["a1b2c3d4-shot.png", "e5f6a7b8-notes.pdf"])
        #expect(outbox.takeStaged(for: "request-1").isEmpty)
        // Removing the last one clears the stage.
        try outbox.stage(["a1b2c3d4-shot.png"], for: "request-2")
        try outbox.stage([], for: "request-2")
        #expect(outbox.takeStaged(for: "request-2").isEmpty)
        // A stage older than the outbox's age is dropped.
        try outbox.stage(["a1b2c3d4-shot.png"], for: "request-3")
        #expect(outbox.takeStaged(for: "request-3", now: Date().addingTimeInterval(PushOutbox.maxAge + 1)).isEmpty)
    }

    @Test func aReplyCarriesItsAttachmentsAndATerminalReplyNever() throws {
        let payload = chief(body: reply, tail: [reply])
        let withPhoto = try #require(PushReply(payload: payload, button: .reply, text: "  look  ", attachments: ["p.png"]))
        #expect(withPhoto.action == .text("look", attachments: ["p.png"]))
        // A photo alone is a reply too.
        #expect(PushReply(payload: payload, button: .reply, text: "", attachments: ["p.png"])?.action == .text("", attachments: ["p.png"]))
        #expect(PushReply(payload: payload, button: .reply, text: " ") == nil)
        let terminal = PushPayload(mac: "m", kind: .terminal, notificationId: "n1", replyable: true)
        #expect(PushReply(payload: terminal, button: .terminalReply, text: "ls", attachments: ["p.png"])?.action == .text("ls", attachments: []))
    }

    /// Review finding (9061d497): a file keeps its original date when copied or moved, so
    /// one last edited days ago was pruned as expired before its Reply read it.
    @Test func anAdoptedOldFileIsDatedNowAndSurvivesThePrune() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("push-adopt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outbox = PushOutbox(directory: dir.appendingPathComponent("outbox", isDirectory: true))
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        for name in ["report.pdf", "photo.jpg"] {
            let source = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        }
        try outbox.adopt(dir.appendingPathComponent("report.pdf"), as: "a1-report.pdf", move: true)
        try outbox.adopt(dir.appendingPathComponent("photo.jpg"), as: "b2-photo.jpg", move: false)
        try outbox.stage(["a1-report.pdf", "b2-photo.jpg"], for: "request-1")
        outbox.pruneAttachments()
        #expect(outbox.takeStaged(for: "request-1") == ["a1-report.pdf", "b2-photo.jpg"])
        // A name that is a path is refused.
        #expect(throws: PushOutbox.Refused.self) { try outbox.adopt(dir.appendingPathComponent("x"), as: "../x", move: false) }
    }

    @Test func aStageNeverRepliedToIsPruned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("push-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = PushOutbox(directory: dir)
        try outbox.stage(["a.png"], for: "dismissed")
        outbox.pruneAttachments(now: Date().addingTimeInterval(PushOutbox.maxAge + 1))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outbox.staged.path))?.isEmpty ?? true)
    }
}
