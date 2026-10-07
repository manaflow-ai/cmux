import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationMentionEditingTests {
    let people = [
        ConversationParticipant(id: "me", name: "Aziz Albahar", initials: "AA", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#FF9F0A", isMe: false),
        ConversationParticipant(id: "lo", name: "Leo Li", initials: "LL", colorHex: "#BF5AF2", isMe: false),
        ConversationParticipant(id: "aw", name: "Austin Wang", initials: "AW", colorHex: "#30D158", isMe: false),
    ]

    func draft(_ text: String) -> ConversationMentionDraft { ConversationMentionDraft(text: text) }

    @Test func atSignListsEveryoneButMeThenFiltersByPrefix() throws {
        let all = try #require(ConversationMentionEditing.query(in: draft("hi @"), caret: 4, participants: people))
        #expect(all.kind == .explicit)
        #expect(all.matches.map(\.id) == ["lc", "lo", "aw"])
        #expect(all.location == 3 && all.length == 1)
        let le = try #require(ConversationMentionEditing.query(in: draft("hi @le"), caret: 6, participants: people))
        #expect(le.matches.map(\.id) == ["lo"])
        // Last names match too; nothing matches -> no query.
        #expect(ConversationMentionEditing.query(in: draft("@wa"), caret: 3, participants: people)?.matches.map(\.id) == ["aw"])
        #expect(ConversationMentionEditing.query(in: draft("@zz"), caret: 3, participants: people) == nil)
        // An "@" inside a word is an email, not a mention.
        #expect(ConversationMentionEditing.query(in: draft("a@le"), caret: 4, participants: people) == nil)
        // I can't mention myself.
        #expect(ConversationMentionEditing.query(in: draft("@aziz"), caret: 5, participants: people) == nil)
    }

    @Test func aTypedFullNameTurnsIntoACompletedNameCandidate() throws {
        let q = try #require(ConversationMentionEditing.query(in: draft("thanks lawrence"), caret: 15, participants: people))
        #expect(q.kind == .completedName)
        #expect(q.location == 7 && q.length == 8)
        // Still a candidate right after the space that follows it.
        #expect(ConversationMentionEditing.query(in: draft("thanks lawrence "), caret: 16, participants: people)?.location == 7)
        // A partial name is not.
        #expect(ConversationMentionEditing.query(in: draft("thanks lawr"), caret: 11, participants: people) == nil)
        // "First Last" prefers the whole name.
        let full = try #require(ConversationMentionEditing.query(in: draft("ok Leo Li"), caret: 9, participants: people))
        #expect(full.location == 3 && full.length == 6 && full.matches.map(\.id) == ["lo"])
    }

    @Test func committingReplacesTheQueryWithTheFirstNameAndASpace() throws {
        let d = draft("hey @la")
        let q = try #require(ConversationMentionEditing.query(in: d, caret: 7, participants: people))
        let result = ConversationMentionEditing.commit(q, participant: people[1], in: d)
        #expect(result.draft.text == "hey Lawrence ")
        #expect(result.draft.mentions == [ConversationMention(participantID: "lc", location: 4, length: 8)])
        #expect(result.caret == 13)
        // A committed mention is no longer a query.
        #expect(ConversationMentionEditing.query(in: result.draft, caret: 13, participants: people) == nil)
    }

    @Test func backspaceIntoAMentionDeletesTheWholeToken() {
        let d = ConversationMentionDraft(text: "hey Lawrence ok", mentions: [ConversationMention(participantID: "lc", location: 4, length: 8)])
        let result = ConversationMentionEditing.apply(NSRange(location: 11, length: 1), replacement: "", to: d)
        #expect(result.range == NSRange(location: 4, length: 8))
        #expect(result.draft.text == "hey  ok")
        #expect(result.draft.mentions.isEmpty)
        #expect(result.caret == 4)
    }

    @Test func typingInsideAMentionRevertsItAndEditsAroundItShift() {
        let d = ConversationMentionDraft(text: "hey Leo and Austin", mentions: [
            ConversationMention(participantID: "lo", location: 4, length: 3),
            ConversationMention(participantID: "aw", location: 12, length: 6),
        ])
        let inside = ConversationMentionEditing.apply(NSRange(location: 5, length: 0), replacement: "x", to: d)
        #expect(inside.draft.mentions == [ConversationMention(participantID: "aw", location: 13, length: 6)])
        let before = ConversationMentionEditing.apply(NSRange(location: 0, length: 3), replacement: "hello", to: d)
        #expect(before.draft.mentions.map(\.location) == [6, 14])
        // Typing right after a mention does not extend it.
        let after = ConversationMentionEditing.apply(NSRange(location: 7, length: 0), replacement: "!", to: d)
        #expect(after.draft.mentions.first == ConversationMention(participantID: "lo", location: 4, length: 3))
        #expect(after.draft.text == "hey Leo! and Austin")
    }

    @Test func typingAtTheEndAfterAMentionAppends() {
        let d = ConversationMentionDraft(text: "hi Leo ", mentions: [ConversationMention(participantID: "lo", location: 3, length: 3)])
        let result = ConversationMentionEditing.apply(NSRange(location: 7, length: 0), replacement: "x", to: d)
        #expect(result.range == NSRange(location: 7, length: 0))
        #expect(result.draft.text == "hi Leo x")
        #expect(result.draft.mentions == d.mentions)
    }

    @Test func rangesAreUTF16() throws {
        let d = draft("🎉 @le")
        let q = try #require(ConversationMentionEditing.query(in: d, caret: 6, participants: people))
        #expect(q.location == 3)
        let result = ConversationMentionEditing.commit(q, participant: people[2], in: d)
        #expect(result.draft.text == "🎉 Leo ")
        #expect((result.draft.text as NSString).substring(with: result.draft.mentions[0].nsRange) == "Leo")
    }

    @Test func invalidWireRangesAreDropped() {
        let message = ConversationMessage(id: "m", seq: 1, clientMessageID: nil, senderID: "lc", sentAt: Date(), text: "hi Leo", mentions: [
            ConversationMention(participantID: "lo", location: 3, length: 3),
            ConversationMention(participantID: "aw", location: 4, length: 10),
            ConversationMention(participantID: "me", location: 4, length: 2),
        ])
        #expect(message.validMentions == [ConversationMention(participantID: "lo", location: 3, length: 3)])
        #expect(message.mentions(participantID: "lo"))
        #expect(!message.mentions(participantID: "aw"))
    }

    @Test func wireRoundTrip() {
        let raw: [String: Any] = [
            "id": "g_1", "seq": 1, "senderId": "lc", "sentAt": 1000, "text": "Aziz look",
            "mentions": [["participantId": "aziz", "location": 0, "length": 4]],
        ]
        let message = WireDecoding.message(raw, base: URL(string: "http://x")!)
        #expect(message?.mentions == [ConversationMention(participantID: "aziz", location: 0, length: 4)])
        let wire = WireDecoding.wireMention(ConversationMention(participantID: "aziz", location: 0, length: 4))
        #expect(wire["participantId"] as? String == "aziz" && wire["length"] as? Int == 4)
    }
}

@MainActor
@Suite struct ConversationMentionStoreTests {
    @Test func sendShiftsMentionsPastTrimmedWhitespaceAndCarriesThemToTheBackend() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "c1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let rowID = try #require(store.send(text: "  hey Lawrence  ", mentions: [ConversationMention(participantID: "lc", location: 6, length: 8)]))
        let pending = try #require(store.message(rowID: rowID))
        #expect(pending.text == "hey Lawrence")
        #expect(pending.mentions == [ConversationMention(participantID: "lc", location: 4, length: 8)])
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(store.message(rowID: rowID)?.mentions == [ConversationMention(participantID: "lc", location: 4, length: 8)])
    }

    @Test func anEditKeepsOnlyMentionsWhoseTextIsUnchanged() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "c1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let rowID = try #require(store.send(text: "Austin and Lawrence", mentions: [
            ConversationMention(participantID: "aw", location: 0, length: 6),
            ConversationMention(participantID: "lc", location: 11, length: 8),
        ]))
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        let id = try #require(store.message(rowID: rowID)?.id)
        store.edit(messageID: id, text: "Austin and Leo")
        #expect(store.message(id: id)?.mentions == [ConversationMention(participantID: "aw", location: 0, length: 6)])
    }
}
