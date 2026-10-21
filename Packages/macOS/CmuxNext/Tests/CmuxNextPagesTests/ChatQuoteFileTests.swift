@testable import CmuxNextPages
import Foundation
import Testing

/// A quote reaches the Home composer as a file named by its card title, holding its Markdown.
struct ChatQuoteFileTests {
    @Test func theFileIsNamedByTheTitleAndHoldsTheMarkdown() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let quote = ChatQuote(source: "/r/docs/a.md", kind: .markdown, lines: 2...3, quoted: "x\ny", comment: "Why?")
        let file = try ChatQuoteFile(folder: folder).write(quote)
        #expect(file.lastPathComponent == "a.md · L2–3.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == quote.markdown)
    }

    @Test func aWebTitleHasNoSlash() {
        #expect(ChatQuoteFile.fileStem("example.com/docs/page") == "example.com-docs-page")
        #expect(ChatQuoteFile.fileStem("  ") == "Quote")
    }
}
