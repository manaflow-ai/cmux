import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// PROTOCOL.md "Push notifications (API 0.12.0)": what the phone reads from a
/// push and which buttons it offers.
@Suite struct PushPayloadTests {
    /// The example payload in PROTOCOL.md, as APNs hands it over.
    func question(options: Int = 2, multi: Bool = false, other: Bool = true) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "Claude asks"]],
         "cmuxMobile": [
            "v": 2, "mac": "mac-1", "macName": "Mac mini", "kind": "question", "eventId": "p-1",
            "agent": "Claude", "place": "cmux-next", "workspace": "cmux-next", "workspaceId": "ws-1",
            "tabId": "t-1", "sessionId": "s-1", "permissionId": "perm-1", "title": "Which branch?",
            "questions": [["question": "Which branch?", "multiSelect": multi, "allowsOther": other,
                           "options": (0..<options).map { ["label": "b\($0)"] }]],
            "tail": ["last line"], "state": "waiting", "previews": true,
         ] as [String: Any]]
    }

    @Test func readsTheV2Payload() throws {
        let p = try #require(PushPayload(userInfo: question()))
        #expect(p.v == 2 && p.kind == .question && p.mac == "mac-1" && p.macName == "Mac mini")
        #expect(p.sessionId == "s-1" && p.permissionId == "perm-1" && p.workspaceId == "ws-1" && p.tabId == "t-1")
        #expect(p.questions.first?.options.map(\.label) == ["b0", "b1"])
        #expect(p.tail == ["last line"] && p.state == .waiting && p.previews)
        #expect(p.threadIdentifier == "mac-1:s-1")
        #expect(p.category == .question)
    }

    @Test func readsAV1Payload() throws {
        let v1: [AnyHashable: Any] = ["cmuxMobile": ["mac": "m", "kind": "completed", "eventId": "t-1", "sessionId": "s"]]
        let p = try #require(PushPayload(userInfo: v1))
        #expect(p.v == 1 && p.kind == .completed && p.previews && p.questions.isEmpty)
        #expect(p.category == .completed)
    }

    @Test func refusesOtherNotificationsAndUnknownKinds() {
        #expect(PushPayload(userInfo: ["aps": ["alert": "x"]]) == nil)
        #expect(PushPayload(userInfo: ["cmuxMobile": ["mac": "m", "kind": "party"]]) == nil)
    }

    @Test func aMalformedListCostsOnlyThatList() throws {
        let bad: [AnyHashable: Any] = ["cmuxMobile": ["mac": "m", "kind": "permission", "options": "nope", "title": "rm -rf build"]]
        let p = try #require(PushPayload(userInfo: bad))
        #expect(p.options.isEmpty && p.title == "rm -rf build")
    }

    @Test func roundTripsThroughUserInfo() throws {
        let p = try #require(PushPayload(userInfo: question()))
        #expect(PushPayload(userInfo: p.userInfo) == p)
    }

    @Test func threadsByTabAndChief() {
        #expect(PushPayload(mac: "m", kind: .terminal, tabId: "s7").threadIdentifier == "m:s7")
        #expect(PushPayload(mac: "m", kind: .chief, conversationId: "home").threadIdentifier == "m:chief:home")
    }

    @Test func singleChoiceUpToFourOptionsGetsItsOwnButtons() throws {
        let p = try #require(PushPayload(userInfo: question(options: 4, other: false)))
        let plan = PushActions().plan(for: p)
        #expect(plan.map(\.action) == [.option(0), .option(1), .option(2), .option(3)])
        #expect(plan.map(\.title) == ["b0", "b1", "b2", "b3"])
        // Free text adds "Answer…".
        let withOther = try #require(PushPayload(userInfo: question(options: 2, other: true)))
        #expect(PushActions().plan(for: withOther).map(\.action) == [.option(0), .option(1), .answer])
    }

    @Test func formsGetAnswer() throws {
        for p in [question(options: 5), question(options: 2, multi: true), question(options: 0)] {
            let payload = try #require(PushPayload(userInfo: p))
            #expect(payload.category == .questionForm)
            #expect(PushActions().plan(for: payload).map(\.action) == [.answer])
        }
    }

    @Test func permissionButtonsFollowTheOfferedOptions() {
        var p = PushPayload(mac: "m", kind: .permission, options: [
            PushOption(id: "a", label: "Allow", kind: .allowOnce), PushOption(id: "r", label: "Reject", kind: .rejectOnce),
        ])
        #expect(PushActions().plan(for: p).map(\.action) == [.allowOnce, .deny])
        p.options.append(PushOption(id: "aa", label: "Always", kind: .allowAlways))
        // Never Always allow (acpmux refuses a lasting grant from a phone).
        #expect(PushActions().plan(for: p).map(\.action) == [.allowOnce, .deny])
        // None listed (a v1 push, or a sealed one the Mac trimmed to fit): "Answer…" opens the app.
        #expect(PushActions().plan(for: PushPayload(mac: "m", kind: .permission)).map(\.action) == [.answer])
    }

    /// The Mac trims a sealed push to fit 3072 characters and may drop the
    /// questions: the ask then opens the app ("Answer…"), never option buttons.
    @Test func aTrimmedAskOpensTheApp() {
        #expect(PushActions().plan(for: PushPayload(mac: "m", kind: .question, permissionId: "q")).map(\.action) == [.answer])
        let empty = PushPayload(mac: "m", kind: .question, questions: [PushQuestion(question: "Which?", options: [])])
        #expect(PushActions().plan(for: empty).map(\.action) == [.answer])
    }

    @Test func turnsAndChiefGetReplyAndTerminalNothingYet() {
        for kind in [PushKind.completed, .failed, .chief] {
            #expect(PushActions().plan(for: PushPayload(mac: "m", kind: kind)).map(\.action) == [.reply])
        }
        #expect(PushActions().plan(for: PushPayload(mac: "m", kind: .terminal)).isEmpty)
    }

    @Test func signedActionsOpenTheAppAndNeedUnlock() {
        let actions = PushActions()
        for a in [PushAction.option(0), .allowOnce, .allowAlways] {
            let built = actions.action(a)
            #expect(built.options.contains(.foreground) && built.options.contains(.authenticationRequired))
        }
        let deny = actions.action(.deny)
        #expect(!deny.options.contains(.foreground) && deny.options.contains(.authenticationRequired) && deny.options.contains(.destructive))
        let reply = actions.action(.reply)
        #expect(reply is UNTextInputNotificationAction && !reply.options.contains(.foreground) && reply.options.contains(.authenticationRequired))
    }

    @Test func everyCategoryIsRegistered() {
        let ids = Set(PushActions().categories.map(\.identifier))
        #expect(ids == Set(PushCategory.allCases.map(\.rawValue)))
        #expect(ids.contains("CMUX_MOBILE_QUESTION_FORM") && ids.contains("CMUX_MOBILE_TERMINAL") && ids.contains("CMUX_MOBILE_RETRY"))
    }

    @Test func actionIdentifiersRoundTrip() {
        for a in [PushAction.option(3), .answer, .allowOnce, .allowAlways, .deny, .reply, .terminalReply, .retry] {
            #expect(PushAction(identifier: a.identifier) == a)
        }
        #expect(PushAction(identifier: "cmux.option.-1") == nil)
        #expect(PushAction(identifier: UNNotificationDefaultActionIdentifier) == nil)
    }
}

@Suite struct PushReplyTests {
    let permission = PushPayload(mac: "m", macName: "Mac", kind: .permission, sessionId: "s", permissionId: "p", options: [
        PushOption(id: "a", label: "Allow", kind: .allowOnce), PushOption(id: "aa", label: "Always", kind: .allowAlways),
        PushOption(id: "ra", label: "Never", kind: .rejectAlways), PushOption(id: "r", label: "Reject", kind: .rejectOnce),
    ])

    @Test func buttonsBecomeReplies() throws {
        #expect(try #require(PushReply(payload: permission, button: .allowOnce)).action == .allow(optionID: "a"))
        #expect(PushReply(payload: permission, button: .allowAlways) == nil)
        // Deny is the one-time reject, never the lasting one.
        #expect(try #require(PushReply(payload: permission, button: .deny)).action == .deny(optionID: "r"))
        let reply = try #require(PushReply(payload: PushPayload(mac: "m", kind: .completed, sessionId: "s"), button: .reply, text: "  go on \n"))
        #expect(reply.action == .text("go on", attachments: []) && reply.sessionId == "s" && reply.mac == "m")
        #expect(!reply.action.needsFaceID && PushReply.Action.allow(optionID: "a").needsFaceID)
    }

    @Test func refusesWhatThePushDoesNotOffer() {
        #expect(PushReply(payload: PushPayload(mac: "m", kind: .permission), button: .allowAlways) == nil)
        #expect(PushReply(payload: PushPayload(mac: "m", kind: .completed), button: .reply, text: "  ") == nil)
        #expect(PushReply(payload: PushPayload(mac: nil, kind: .completed), button: .reply, text: "x") == nil)
        #expect(PushReply(payload: permission, button: .option(0)) == nil)
    }

    @Test func roundTripsThroughTheRetryStore() throws {
        let reply = try #require(PushReply(payload: permission, action: .answers(selected: [["a", "b"]], other: ["c"])))
        let store = PushRetryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString)"))
        try store.put(reply)
        #expect(store.resolve(userInfo: reply.retryUserInfo, fromPush: false) == reply)
    }
}

@Suite struct PushOutboxTests {
    func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func putTakeAll() throws {
        let box = PushOutbox(directory: temp())
        let now = Date()
        let a = PushReply(mac: "m", kind: .completed, action: .text("a", attachments: []), createdAt: now.addingTimeInterval(-5))
        let b = PushReply(mac: "m", kind: .completed, action: .text("b", attachments: []), createdAt: now)
        try box.put(b)
        try box.put(a)
        #expect(box.all(now: now).map(\.id) == [a.id, b.id])
        #expect(box.take(a.id) == a)
        #expect(box.take(a.id) == nil)
        #expect(box.takeAll(now: now) == [b])
        #expect(box.all(now: now).isEmpty)
    }

    @Test func dropsExpiredReplies() throws {
        let box = PushOutbox(directory: temp())
        let old = PushReply(mac: "m", kind: .completed, action: .text("a", attachments: []), createdAt: Date(timeIntervalSince1970: 0))
        try box.put(old)
        #expect(box.all().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: box.directory.path))?.isEmpty == true)
    }

    @Test func snapshotsAreBounded() throws {
        let store = PushSnapshotStore(directory: temp())
        let long = String(repeating: "x", count: 1000)
        store.save(PushSnapshot(mac: "m", session: "s/1", messages: (0..<20).map { .init(role: .agent, text: "\($0)" + long) }))
        let saved = try #require(store.load(mac: "m", session: "s/1"))
        #expect(saved.messages.count == PushSnapshotStore.maxMessages)
        #expect(saved.messages.first?.text.hasPrefix("12") == true)
        #expect(saved.messages.allSatisfy { $0.text.count == PushSnapshotStore.maxCharacters })
        #expect(store.load(mac: "m", session: "other") == nil)
        for i in 0..<(PushSnapshotStore.maxSessions + 5) {
            store.save(PushSnapshot(mac: "m", session: "s\(i)", messages: [.init(role: .user, text: "hi")]))
        }
        let count = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count
        #expect(count == PushSnapshotStore.maxSessions)
    }
}
