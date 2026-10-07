import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationRichTextTests {
    @Test func normalizeClipsDropsPlainResolvesOverlapAndMerges() {
        let runs = [
            ConversationTextRun(location: 8, length: 10, style: [.bold]),
            ConversationTextRun(location: 0, length: 2, style: [.italic]),
            ConversationTextRun(location: 2, length: 2, style: [.italic]),
            ConversationTextRun(location: 5, length: 0, style: [.bold]),
            ConversationTextRun(location: 6, length: 1),
            ConversationTextRun(location: 9, length: 1, effect: .shake),
        ]
        #expect(ConversationRichText.normalized(runs, utf16Count: 12) == [
            ConversationTextRun(location: 0, length: 4, style: [.italic]),
            ConversationTextRun(location: 8, length: 1, style: [.bold]),
            ConversationTextRun(location: 9, length: 1, effect: .shake),
            ConversationTextRun(location: 10, length: 2, style: [.bold]),
        ])
    }

    @Test func trimmingShiftsRunsIntoTheSentText() {
        let (text, runs) = ConversationRichText.trimmed("  hi there \n", runs: [
            ConversationTextRun(location: 0, length: 4, style: [.bold]),
            ConversationTextRun(location: 5, length: 7, effect: .bloom),
        ])
        #expect(text == "hi there")
        #expect(runs == [
            ConversationTextRun(location: 0, length: 2, style: [.bold]),
            ConversationTextRun(location: 3, length: 5, effect: .bloom),
        ])
    }

    @Test func runsUseUTF16OffsetsAroundEmoji() {
        let text = "👋🏽 wave"
        let string = NSMutableAttributedString(string: text)
        let wave = (text as NSString).range(of: "wave")
        ConversationRichText.toggle(.explode, in: wave, of: string)
        #expect(ConversationRichText.runs(in: string) == [ConversationTextRun(location: wave.location, length: 4, effect: .explode)])
        #expect(wave.location == text.utf16.count - 4)
    }

    @Test func styleToggleAddsUnlessTheWholeRangeHasIt() {
        let string = NSMutableAttributedString(string: "bold move")
        #expect(ConversationRichText.toggle(.bold, in: NSRange(location: 0, length: 4), of: string))
        // Mixed selection: turning bold on covers the rest.
        #expect(ConversationRichText.toggle(.bold, in: NSRange(location: 0, length: 9), of: string))
        #expect(ConversationRichText.runs(in: string) == [ConversationTextRun(location: 0, length: 9, style: [.bold])])
        ConversationRichText.toggle(.underline, in: NSRange(location: 5, length: 4), of: string)
        #expect(!ConversationRichText.toggle(.bold, in: NSRange(location: 0, length: 9), of: string))
        #expect(ConversationRichText.runs(in: string) == [ConversationTextRun(location: 5, length: 4, style: [.underline])])
    }

    @Test func choosingTheSameEffectAgainRemovesIt() {
        let string = NSMutableAttributedString(string: "wow")
        let all = NSRange(location: 0, length: 3)
        #expect(ConversationRichText.toggle(.ripple, in: all, of: string) == .ripple)
        #expect(ConversationRichText.toggle(.jitter, in: all, of: string) == .jitter)
        #expect(ConversationRichText.toggle(.jitter, in: all, of: string) == nil)
        #expect(ConversationRichText.runs(in: string).isEmpty)
    }

    @Test func applyThenReadRoundTrips() {
        let runs = [
            ConversationTextRun(location: 0, length: 3, style: [.bold, .strikethrough]),
            ConversationTextRun(location: 3, length: 2, style: [.bold], effect: .nod),
        ]
        let string = NSMutableAttributedString(string: "hello world")
        ConversationRichText.apply(runs, to: string)
        #expect(ConversationRichText.runs(in: string) == runs)
    }

    @Test func wireRunsDecodeAndEncode() {
        let raw: [[String: Any]] = [
            ["start": 0, "length": 5, "styles": ["italic", "bold", "sparkle"]],
            ["start": 6, "length": 5, "effect": "big"],
            ["start": 20, "length": 5, "effect": "big"],
            ["start": 1, "length": 1, "effect": "wobble"],
        ]
        let runs = WireDecoding.textRuns(raw, text: "hello world")
        #expect(runs == [
            ConversationTextRun(location: 0, length: 1, style: [.bold, .italic]),
            ConversationTextRun(location: 1, length: 1),
            ConversationTextRun(location: 2, length: 3, style: [.bold, .italic]),
            ConversationTextRun(location: 6, length: 5, effect: .big),
        ].filter { !$0.isPlain })
        let encoded = WireDecoding.wireRuns([ConversationTextRun(location: 0, length: 5, style: [.italic, .bold])])
        #expect(encoded.first?["styles"] as? [String] == ["bold", "italic"])
        #expect(encoded.first?["effect"] == nil)
    }

    @Test func decodedMessageCarriesRuns() throws {
        let raw: [String: Any] = [
            "id": "m1", "senderId": "lc", "text": "big news", "sentAt": 1000,
            "textRuns": [["start": 0, "length": 8, "effect": "big"]],
        ]
        let message = try #require(WireDecoding.message(raw, base: URL(string: "http://x")!))
        #expect(message.textRuns == [ConversationTextRun(location: 0, length: 8, effect: .big)])
    }
}

@MainActor
@Suite struct ConversationStoreRichTextTests {
    @Test func sendCarriesTrimmedRunsOnThePendingRowAndTheDraft() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let rowID = try #require(store.send(text: " yes please", textRuns: [
            ConversationTextRun(location: 1, length: 3, effect: .nod),
            ConversationTextRun(location: 5, length: 6, style: [.italic]),
        ]))
        let expected = [
            ConversationTextRun(location: 0, length: 3, effect: .nod),
            ConversationTextRun(location: 4, length: 6, style: [.italic]),
        ]
        #expect(store.message(rowID: rowID)?.textRuns == expected)
        try await waitUntil { backend.sendCount == 1 }
        #expect(backend.sentDrafts.first?.textRuns == expected)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(store.message(rowID: rowID)?.textRuns == expected)
    }

    @Test func editReplacesFormattingAndAFormattingOnlyEditApplies() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date()
        store.apply(.message(mine, eventSeq: 1))
        let runs = [ConversationTextRun(location: 0, length: 7, style: [.bold])]
        store.edit(messageID: "m7", text: mine.text, textRuns: runs)
        #expect(store.message(id: "m7")?.textRuns == runs)
        #expect(store.message(id: "m7")?.editedAt != nil)
    }
}
