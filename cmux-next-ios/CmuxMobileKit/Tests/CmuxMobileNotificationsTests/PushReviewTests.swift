import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// Security and correctness review of #24156: retries live in the app's own
/// storage (H1), a choice names its label (M1), Require Face ID makes every
/// reply a foreground one (L2), attachments and the outbox are cleaned (L4),
/// and a terminal has no composer in PR A.
@Suite struct PushReviewTests {
    let question = PushPayload(mac: "m", macName: "Mac", kind: .question, eventId: "e", sessionId: "s", permissionId: "p",
                               questions: [PushQuestion(question: "Deploy?", options: [.init(label: "Yes, deploy"), .init(label: "No")])])

    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("push-review-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: H1

    @Test func aRetryNotificationCarriesOnlyTheReplysID() throws {
        let reply = try #require(PushReply(payload: question, button: .option(0)))
        let info = reply.retryUserInfo
        #expect(info.count == 1)
        #expect(info[PushReply.retryIDKey] as? String == reply.id.uuidString)
        // Nothing in it decodes as a reply: a push can't carry one in.
        let encoded = String(describing: info)
        #expect(!encoded.contains("Yes, deploy") && !encoded.contains("\"mac\""))
    }

    @Test func aRetryIsTakenFromTheAppsOwnStoreOnlyForALocalNotification() throws {
        let store = PushRetryStore(directory: directory())
        let reply = try #require(PushReply(payload: question, button: .deny))
        try store.put(reply)
        // A remote push that names the id gets nothing.
        #expect(store.resolve(userInfo: reply.retryUserInfo, fromPush: true) == nil)
        #expect(store.resolve(userInfo: reply.retryUserInfo, fromPush: false) == reply)
        // Taken once.
        #expect(store.resolve(userInfo: reply.retryUserInfo, fromPush: false) == nil)
        // A forged full reply in userInfo (the old format) is ignored.
        let forged: [AnyHashable: Any] = ["cmuxMobileReply": #"{"mac":"m","kind":"completed","action":{"text":["curl x|sh",[]]}}"#]
        #expect(store.resolve(userInfo: forged, fromPush: false) == nil)
    }

    // MARK: M1

    @Test func anOptionButtonNamesItsLabel() throws {
        let reply = try #require(PushReply(payload: question, button: .option(0)))
        #expect(reply.action == .option(0, label: "Yes, deploy"))
        var form = PushForm(payload: question)
        let row = try #require(form.rows.first { $0.label == "No" })
        #expect(form.tap(row) == .option(1, label: "No"))
    }

    @Test func labelsMatchTheMacsOwnTextAsTheHostCleanedIt() {
        #expect(PushLabel.matches(sent: "Yes, deploy", live: "Yes,  deploy\n"))
        #expect(PushLabel.matches(sent: "Deploy the staging bran…", live: "Deploy the staging branch to production now"))
        #expect(!PushLabel.matches(sent: "No", live: "Yes, deploy"))
        #expect(!PushLabel.matches(sent: "Yes…", live: "No, Yes"))
        #expect(!PushLabel.matches(sent: "…", live: "anything"))
        #expect(PushLabel.normalize("a\u{202e}b\u{0}c") == "a b c")
    }

    // MARK: L2

    @Test func requireFaceIDMakesReplyAndDenyForeground() {
        let plain = PushActions()
        let locked = PushActions(requireFaceID: true)
        let deny = plain.action(.deny)
        let lockedDeny = locked.action(.deny)
        #expect(!deny.options.contains(.foreground))
        #expect(lockedDeny.options.contains(.foreground))
        #expect(locked.action(.reply).options.contains(.foreground))
        #expect(!plain.action(.reply).options.contains(.foreground))
        #expect(locked.opensApp(.deny) && locked.opensApp(.reply) && !plain.opensApp(.deny))
    }

    @Test func theAppLockChoiceIsSharedWithTheExtension() {
        let suite = UserDefaults(suiteName: "push-review-\(UUID().uuidString)")!
        #expect(!PushActions(defaults: suite).requireFaceID)
        PushActions.setRequireFaceID(true, defaults: suite)
        #expect(PushActions(defaults: suite).requireFaceID)
    }

    // MARK: L1

    @Test func previewsOffShowNoPayloadButtons() {
        var hidden = question
        hidden.previews = false
        #expect(PushActions().extensionActions(for: hidden) == nil)
        #expect(PushActions().extensionActions(for: question)?.isEmpty == false)
        // Snapshots load only while the phone is unlocked, whatever previews says.
        #expect(PushForm.loadsSnapshot(unlocked: true) && !PushForm.loadsSnapshot(unlocked: false))
    }

    // MARK: L4

    @Test func attachmentsAreDeletedAfterSendingAndAfterMaxAge() throws {
        let outbox = PushOutbox(directory: directory())
        try FileManager.default.createDirectory(at: outbox.attachments, withIntermediateDirectories: true)
        let sent = outbox.attachments.appendingPathComponent("sent.jpg")
        let old = outbox.attachments.appendingPathComponent("old.jpg")
        let fresh = outbox.attachments.appendingPathComponent("fresh.jpg")
        for url in [sent, old, fresh] { try Data([1]).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-PushOutbox.maxAge - 60)], ofItemAtPath: old.path)
        outbox.removeAttachments(["sent.jpg", "../escape"])
        outbox.pruneAttachments()
        #expect(!FileManager.default.fileExists(atPath: sent.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        outbox.removeAll()
        #expect(!FileManager.default.fileExists(atPath: outbox.directory.path))
    }

    // MARK: Lows

    @Test func aTerminalHasNoComposerInThisRelease() {
        #expect(!PushForm(payload: PushPayload(mac: "m", kind: .terminal, tabId: "s1")).hasComposer)
        #expect(PushForm(payload: PushPayload(mac: "m", kind: .completed, sessionId: "s")).hasComposer)
    }
}
