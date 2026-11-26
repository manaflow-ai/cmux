import Foundation
import Testing
@testable import CmuxConversationCore

/// Group status rows, Delivered Quietly and Notify Anyway.
@Suite struct ConversationSystemEventTests {
    private let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
        ConversationParticipant(id: "aw", name: "Austin #1 Wang", initials: "AW", colorHex: "#8E8E93", isMe: false),
    ])

    private func message(_ seq: Int, _ sender: String, minute: Double, system: ConversationSystemEvent? = nil, delivery: ConversationDelivery? = nil, quietly: Bool = false) -> ConversationMessage {
        ConversationMessage(
            id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: sender,
            sentAt: Date(timeIntervalSince1970: minute * 60), text: system == nil ? "x" : "",
            delivery: delivery, systemEvent: system, deliveredQuietly: quietly
        )
    }

    private func emphasized(_ text: ConversationSystemText) -> [String] {
        text.emphasized.map { (text.text as NSString).substring(with: $0) }
    }

    @Test func templatesSubstitutePositionalArgumentsAndEmphasizeHashSpans() {
        let text = ConversationSystemText.formatted("#%1$@# added %2$@ to the conversation.", ["Lawrence Chen", "Leo Li"])
        #expect(text.text == "Lawrence Chen added Leo Li to the conversation.")
        #expect(emphasized(text) == ["Lawrence Chen"])
        // Japanese reorders around the same positions.
        let ja = ConversationSystemText.formatted("#%1$@#さんが%2$@さんをこのチャットに追加しました。", ["A", "B"])
        #expect(ja.text == "AさんがBさんをこのチャットに追加しました。")
        #expect(emphasized(ja) == ["A"])
    }

    @Test func aHashInsideANameNeverOpensASpan() {
        let text = ConversationSystemText.formatted("#%@# left the conversation.", ["Austin #1 Wang"])
        #expect(text.text == "Austin #1 Wang left the conversation.")
        #expect(emphasized(text) == ["Austin #1 Wang"])
    }

    @Test func statusLinesUseYouForMeAndNamesForOthers() throws {
        func line(_ sender: String, _ event: ConversationSystemEvent) throws -> ConversationSystemText {
            try #require(ConversationStatusStrings.text(for: message(1, sender, minute: 0, system: event), meID: "me", info: info))
        }
        #expect(try line("lc", .init(kind: .named, name: "ship it")).text == "Lawrence Chen named the conversation “ship it”.")
        #expect(try line("me", .init(kind: .named, name: "x")).text == "You named the conversation “x”.")
        #expect(emphasized(try line("me", .init(kind: .left))) == ["You"])
        #expect(try line("lc", .init(kind: .added, targetID: "me")).text == "Lawrence Chen added you to the conversation.")
        #expect(try line("me", .init(kind: .added, targetID: "lc")).text == "You added Lawrence Chen to the conversation.")
        #expect(try line("lc", .init(kind: .removed, targetID: "aw")).text == "Lawrence Chen removed Austin #1 Wang from the conversation.")
        #expect(try line("aw", .init(kind: .left)).text == "Austin #1 Wang left the conversation.")
        #expect(try line("lc", .init(kind: .changedPhoto)).text == "Lawrence Chen changed the group photo.")
        #expect(ConversationStatusStrings.text(for: message(2, "lc", minute: 0), meID: "me", info: info) == nil)
    }

    @Test func aStatusRowBreaksRunsAndIsNotAReplyToMyStatus() {
        let plan = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(2, "lc", minute: 1, system: .init(kind: .changedPhoto)),
            message(3, "lc", minute: 2),
            message(4, "lc", minute: 3),
        ], meID: "me")
        #expect(plan.entries.map(\.isFirstInRun) == [true, true, true, false])
        #expect(plan.entries.map(\.isLastInRun) == [true, true, false, true])
        // Lawrence's text below clears my status; the status row alone would not.
        #expect(plan.entries[0].status == .none)
        let quiet = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered, quietly: true),
            message(2, "lc", minute: 1, system: .init(kind: .left)),
        ], meID: "me")
        #expect(quiet.entries.map(\.status) == [.deliveredQuietly, .none])
    }

    @Test func wireDecodingReadsSystemEventsFocusAndQuietDelivery() throws {
        let base = URL(string: "http://127.0.0.1:4870")!
        let status = try #require(WireDecoding.message([
            "id": "g_9", "seq": 9, "senderId": "lc", "sentAt": 0, "text": "",
            "system": ["kind": "added", "targetId": "aw"],
        ], base: base))
        #expect(status.systemEvent == ConversationSystemEvent(kind: .added, targetID: "aw"))
        // An unknown kind is skipped rather than drawn as an empty bubble.
        #expect(WireDecoding.message(["id": "g_10", "seq": 10, "senderId": "lc", "text": "", "system": ["kind": "teleported"]], base: base) == nil)
        let quiet = try #require(WireDecoding.message([
            "id": "d_3", "seq": 3, "senderId": "me", "text": "hi", "status": "delivered", "deliveredQuietly": true,
        ], base: base))
        #expect(quiet.deliveredQuietly && !quiet.notifiedAnyway)
        let conversation = try #require(WireDecoding.conversation([
            "id": "direct", "title": "John", "kind": "direct",
            "participants": [
                ["id": "me", "name": "Me", "isMe": true],
                ["id": "john", "name": "John Appleseed", "notificationsSilenced": true],
            ],
        ]))
        #expect(conversation.silencedRecipient?.id == "john")
    }
}

@MainActor
@Suite struct ConversationNotificationStateStoreTests {
    @Test func statusRowsAreNeverUnreadOrTheCatchUpTarget() async throws {
        let backend = ScriptedBackend(total: 30)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.readState(ConversationReadState(lastReadSeq: 30, unreadCount: 0, headSeq: 30)))
        var status = backend.makeMessage(seq: 31, sender: "lc")
        status.text = ""
        status.systemEvent = ConversationSystemEvent(kind: .named, name: "cmux")
        store.apply(.message(status, eventSeq: 1))
        #expect(store.unreadCount == 0)
        store.apply(.message(backend.makeMessage(seq: 32, sender: "lc"), eventSeq: 2))
        #expect(store.unreadCount == 1)
        store.setViewing(true)
        #expect(store.catchUpTarget?.seq == 32)
    }

    @Test func notifyAnywayHidesAtOnceAndReturnsWhenRefused() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30)
        var direct = backend.info
        direct.kind = .direct
        direct.participants = [direct.participants[0], direct.participants[1]]
        store.apply(.connected(info: direct, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var mine = backend.makeMessage(seq: 4, sender: "me")
        mine.delivery = .delivered
        mine.deliveredQuietly = true
        store.apply(.message(mine, eventSeq: 1))
        // Not silenced (any more): nothing to offer.
        #expect(store.notifyAnywayMessage == nil)
        direct.participants[1].notificationsSilenced = true
        store.apply(.conversationChanged(direct))
        #expect(store.notifyAnywayMessage?.id == "m4")
        store.notifyAnyway(messageID: "m4")
        #expect(store.notifyAnywayMessage == nil)
        // ScriptedBackend has no notification state, so the request fails and the button returns.
        try await waitUntil { store.notifyAnywayMessage != nil }
        // Once read, the quiet delivery no longer matters.
        mine.delivery = .read(nil)
        store.apply(.message(mine, eventSeq: 2))
        #expect(store.notifyAnywayMessage == nil)
    }
}
