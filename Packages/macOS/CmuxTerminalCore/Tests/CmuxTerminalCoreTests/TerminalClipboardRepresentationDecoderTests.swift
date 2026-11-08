import Testing

@testable import CmuxTerminalCore

@Suite
struct TerminalClipboardRepresentationDecoderTests {
    @Test func rejectsRichPayloadBeyondBudgetBeforeDecoding() {
        let decoder = TerminalClipboardRepresentationDecoder(
            maximumRichTextBytes: 8
        )
        let oversizedHTML = String(repeating: "x", count: 9)

        let representation = oversizedHTML.withCString {
            decoder.decode(mimeType: "text/html", data: $0)
        }

        #expect(representation == nil)
    }

    @Test func preservesRichPayloadAtBudget() {
        let decoder = TerminalClipboardRepresentationDecoder(
            maximumRichTextBytes: 8
        )

        let representation = "<b>x</b>".withCString {
            decoder.decode(mimeType: "text/html", data: $0)
        }

        #expect(
            representation == TerminalClipboardRepresentation(
                mimeType: "text/html",
                string: "<b>x</b>"
            )
        )
    }

    @Test func plainTextRemainsUnbounded() {
        let decoder = TerminalClipboardRepresentationDecoder(
            maximumRichTextBytes: 1
        )

        let representation = "plain text".withCString {
            decoder.decode(mimeType: "text/plain; charset=utf-8", data: $0)
        }

        #expect(
            representation == TerminalClipboardRepresentation(
                mimeType: "text/plain; charset=utf-8",
                string: "plain text"
            )
        )
    }
}
