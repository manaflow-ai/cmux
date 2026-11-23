import CmuxMobileAgentChat
import CmuxMobileLive
import Foundation
import Testing

// `chat_older_page`'s god/small gap (InstantPerfTests.swift): god's first older page carried a
// 2 MB command log whole, since a page always carries its records whole. The phone now asks
// acpmux to cut a tool output past `toolOutputMaxBytes` (64 KiB, `AcpmuxSessionSource`), and
// opening the output reads its record whole. These check both halves on the bench's own fixture
// and fake Mac. Cut, the log fits the open's own page (128 KiB), so the first older page reads
// the turns before it instead.

@MainActor
@Suite("Older page: an oversized tool output comes cut, and opens whole", .serialized)
struct OlderPageToolOutputTests {
    /// What one page may carry (an older read's 256 KiB, `olderBytes`, the open's is 128 KiB):
    /// its records, one record past that (a page always holds its first) cut to 64 KiB
    /// (`toolOutputMaxBytes`), and the reply's own JSON.
    static let pageCap = 256 * 1024 + 64 * 1024 + 16 * 1024

    /// The god log's 2 MB command log in the newest turn: the record the first older page reads.
    static func bigLog(_ log: AgentChatLog) throws -> (index: Int, text: String) {
        let index = try #require(log.bytes.indices.last { log.bytes[$0] > 2_000_000 && log.records[$0].contains(#""type":"text""#) })
        let record = try #require(try JSONSerialization.jsonObject(with: Data(log.records[index].utf8)) as? [String: Any])
        let update = (record["msg"] as? [String: Any])?["params"] as? [String: Any]
        let content = (update?["update"] as? [String: Any])?["content"] as? [[String: Any]]
        let text = try #require((content?.first?["content"] as? [String: Any])?["text"] as? String)
        return (index, text)
    }

    static func call(_ store: AgentChatStore, id: String) -> ACPToolCall? {
        for turn in store.turns.reversed() {
            for item in turn.items {
                if case .tool(let call) = item, call.id == id { return call }
            }
        }
        return nil
    }

    @Test("god's pages stay under their caps, and the cut log opens whole")
    func olderPageCutsTheLogAndItOpensWhole() async throws {
        let log = AgentChatFixture.god
        let big = try Self.bigLog(log)
        let fake = InstantPerfAcpmux(log)
        let (hub, store) = try await InstantPerfTests.openedChat(fake, link: fake.link())
        try #require(store.hasEarlierHistory)
        let before = store.turns.count
        store.loadEarlier()
        let shown = await InstantPerfTests.waitUntil { !store.isLoadingEarlier && store.turns.count > before }
        try #require(shown, "the older page never showed")

        // The page that carried the log (the open's, or an older one): before, the log's 2 MB
        // on top of the page's own bytes.
        let carried = fake.eventReplyLog.filter { $0.records?.contains(big.index) == true }
        try #require(!carried.isEmpty, "no page held the log's record")
        for read in carried {
            #expect(read.bytes <= Self.pageCap, "the page with the log in it was \(read.bytes) bytes")
        }

        // The chat shows the log's head, marked cut with the record's seq.
        let id = try #require(log.records[big.index].firstMatch(of: /"toolCallId":"([^"]+)"/)).1
        let cut = try #require(Self.call(store, id: String(id)))
        let marker = try #require(cut.outputCut, "the log came whole")
        #expect(marker.seq == big.index + 1)
        #expect(cut.outputText.utf8.count < 64 * 1024)
        #expect(big.text.hasPrefix(cut.outputText))

        // The person opens it: the whole log, in place of the cut one.
        let loaded = await store.loadFullOutput(of: cut)
        #expect(loaded, "the whole output's read failed")
        #expect(Self.call(store, id: String(id))?.outputCut == nil, "the whole output never went in place")
        let opened = try #require(Self.call(store, id: String(id)))
        #expect(opened.outputText == big.text)
        #expect(opened.status == cut.status)
        await hub.bind(nil)
    }
}
