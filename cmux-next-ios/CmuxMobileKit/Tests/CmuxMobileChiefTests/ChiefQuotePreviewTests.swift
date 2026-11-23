import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Lawrence, 2026-11-20: the quote above a reply to a Chief message showed its Markdown on the phone too
/// (`![alt](src)` as written; a message that was only a table quoted as "Photo"). A quote shows the message's
/// words, as the Mac's quote and every list row do (CmuxHomeCore `MessagePreview`).
@Suite("A quote of a Chief message shows its words")
struct ChiefQuotePreviewTests {
    let wire = ChiefWire(identity: .standard)

    func message(_ text: String, from author: String? = nil) throws -> ConversationMessage {
        try #require(wire.message(["id": "m1", "seq": 1, "author": author ?? wire.identity.chiefID,
                                   "parts": [["type": "text", "text": text]], "reactions": []], peerReadSeq: 0))
    }

    static let table = "| | Before | After |\n|---|---|---|\n| Light | ![before, light](/tmp/bl.png) | ![after, light](/tmp/al.png) |"

    @Test("a table quotes as its columns")
    func tableQuotesAsItsColumns() throws {
        #expect(try message(Self.table).quoteText == "Table: Before / After")
        #expect(try message("Shots below.\n\n" + Self.table).quoteText == "Shots below. Table: Before / After")
    }

    @Test("pictures quote as their count, links as their labels")
    func picturesAndLinks() throws {
        #expect(try message("![before](/tmp/a.png) ![after](/tmp/b.png)").quoteText == "2 images")
        #expect(try message("**Done.** See [PR 12](https://github.com/manaflow-ai/cmux/pull/12) ![shot](/tmp/a.png)").quoteText == "Done. See PR 12")
    }

    @Test("my own text quotes as typed")
    func myTextQuotesAsTyped() throws {
        #expect(try message("a | b **c**", from: wire.identity.meID).quoteText == "a | b **c**")
    }
}
