import AppKit
import Testing

@testable import CmuxTerminal

// SAFETY: the detached cancellation probe exclusively owns these handles until
// its result is awaited; cleanup and assertions happen afterward on MainActor.
private struct CancelledPasteboardWriteFixture: @unchecked Sendable {
    let service: TerminalPasteboardService
    let pasteboard: NSPasteboard
    let item: NSPasteboardItem
}

@MainActor
@Suite("Terminal pasteboard service review regressions", .serialized)
struct TerminalPasteboardServiceReviewRegressionTests {
    @Test("cancelled caller observes an admitted clipboard write")
    func cancelledCallerObservesAdmittedClipboardWrite() async throws {
        let standard = NSPasteboard(
            name: .init("cmux-cancelled-write-\(UUID().uuidString)")
        )
        let selection = NSPasteboard(
            name: .init("cmux-cancelled-write-selection-\(UUID().uuidString)")
        )
        defer {
            standard.clearContents()
            selection.clearContents()
            standard.releaseGlobally()
            selection.releaseGlobally()
        }
        let service = TerminalPasteboardService(
            standardPasteboard: standard,
            selectionPasteboard: selection
        )
        let item = NSPasteboardItem()
        #expect(item.setString("replacement", forType: .string))

        let fixture = CancelledPasteboardWriteFixture(
            service: service,
            pasteboard: standard,
            item: item
        )
        // This probe exercises the service's intentionally nonisolated caller
        // contract; the unchecked fixture above makes its exclusive lifetime
        // explicit to Swift 6.
        let write = Task.detached {
            await fixture.service.replaceContentsAndWait(
                of: fixture.pasteboard,
                with: [fixture.item]
            )
        }
        write.cancel()

        let result = await write.value
        #expect(result.status == .written)
        #expect(result.didWrite)
        #expect(standard.string(forType: .string) == "replacement")
    }

    @Test("whitespace-only HTML falls through to valid RTF")
    func whitespaceOnlyHTMLFallsThroughToValidRTF() throws {
        let pasteboard = NSPasteboard(
            name: .init("cmux-whitespace-html-rtf-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let attributed = NSAttributedString(string: "RTF fallback")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
        )
        let html = """
            <pre><span hidden>hidden</span>&nbsp;
            &#160;\t</pre>
            """
        let item = NSPasteboardItem()
        #expect(item.setString(html, forType: .html))
        #expect(item.setData(rtf, forType: .rtf))
        #expect(item.setData(Data([0x00]), forType: .rtfd))
        #expect(item.setString("??~", forType: .string))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
        let storedHTML = try #require(pasteboard.string(forType: .html))
        #expect(storedHTML == html)
        #expect(pasteboard.string(forType: .string) == "??~")

        let htmlOutcome = HTMLPlainTextParser().outcome(from: storedHTML)
        guard case .visibleText(let htmlText) = htmlOutcome else {
            Issue.record("expected visible whitespace, got \(htmlOutcome)")
            return
        }
        #expect(
            htmlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "RTF fallback"
        )
    }
}
