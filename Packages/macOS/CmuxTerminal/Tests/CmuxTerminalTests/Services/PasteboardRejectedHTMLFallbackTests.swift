import AppKit
import Testing

@testable import CmuxTerminal

@Suite("Rejected HTML pasteboard fallback", .serialized)
struct PasteboardRejectedHTMLFallbackTests {
    @Test("image with rejected HTML preserves advertised plain text")
    func imageWithRejectedHTMLPreservesPlainText() {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-rejected-html-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let depth = 1_024
        let rejectedHTML = String(repeating: "<div>", count: depth)
            + "rich"
            + String(repeating: "</div>", count: depth)
        pasteboard.declareTypes([.png, .html, .string], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setString(rejectedHTML, forType: .html)
        pasteboard.setString("plain fallback", forType: .string)

        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "plain fallback"
        )
    }

    @Test("image with data-backed rejected HTML preserves advertised plain text")
    func imageWithDataBackedRejectedHTMLPreservesPlainText() {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-data-rejected-html-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        pasteboard.declareTypes([.png, .html, .string], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setData(Data([0xFF, 0xFE, 0x00]), forType: .html)
        pasteboard.setString("plain fallback", forType: .string)

        #expect(pasteboard.string(forType: .html) == nil)
        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "plain fallback"
        )
    }

    @Test("RTFD flavor with rejected HTML preserves advertised plain text")
    func rtfdWithRejectedHTMLPreservesPlainText() {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-rtfd-rejected-html-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let depth = 1_024
        let rejectedHTML = String(repeating: "<div>", count: depth)
            + "rich"
            + String(repeating: "</div>", count: depth)
        pasteboard.declareTypes([.rtfd, .html, .string], owner: nil)
        pasteboard.setData(Data([0x00]), forType: .rtfd)
        pasteboard.setString(rejectedHTML, forType: .html)
        pasteboard.setString("plain fallback", forType: .string)

        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "plain fallback"
        )
    }

    @Test("image with rejected HTML falls through to valid RTF")
    func imageWithRejectedHTMLFallsThroughToRTF() throws {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-rejected-html-rtf-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let rejectedHTML = String(
            repeating: "<div>",
            count: 1_024
        ) + "rich" + String(repeating: "</div>", count: 1_024)
        let attributed = NSAttributedString(string: "RTF fallback")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.declareTypes([.png, .html, .string, .rtf], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setString(rejectedHTML, forType: .html)
        pasteboard.setString("??~", forType: .string)
        pasteboard.setData(rtf, forType: .rtf)

        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "RTF fallback"
        )
    }
}
