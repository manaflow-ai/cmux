import Testing
@testable import MessagesLabHome

/// A long streaming reply whose end is rewritten (a Markdown style that closes rewrites its last
/// line and can shorten the text) keeps its index lineage: only its last blocks are scanned again,
/// not the whole reply (the vendored LongTextStore, cmux patch).
@MainActor @Suite(.serialized) struct LongTextStreamRewriteTests {
    @Test func aRewrittenEndKeepsTheLineage() throws {
        let store = LongTextStore()
        var text = ""
        for i in 0..<400 { text += "line \(i) of a long streaming reply with some words in it\n" }
        text += "the last line has **bol"
        #expect(LongText.isLong(text))
        _ = store.size(text, width: 760)
        let first = try #require(store.lineage(text))
        // The style closes: the markers go, the text gets shorter.
        let rewritten = String(text.dropLast("**bol".count)) + "bold"
        // This store's own count: LongTextStats is process-wide, and a suite that runs at the same time
        // (CatalystCachesSendableTests builds indexes on many threads) moves it.
        let builds = store.lineagesIssued
        _ = store.size(rewritten, width: 760)
        #expect(store.lineage(rewritten) == first)
        #expect(store.lineagesIssued == builds, "no index from the start")
        // A different text with the same start but no shared block still gets its own lineage.
        let other = String(text.prefix(300)) + "different"
        _ = store.size(other, width: 760)
        #expect(store.lineage(other) != first)
    }
}
