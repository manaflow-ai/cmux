import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): the store reducer and the byte and
/// character scanners (long markdown cut, code highlight, Home inline markdown) refuse or
/// clamp instead of trapping. Seeded.
@MainActor @Suite struct EngineAndScannerFuzzTests {
    static func store(_ n: Int) -> Store {
        let messages = (0..<n).map { i in
            Message(id: "m\(i)", senderId: i % 2 == 0 ? "me" : "them", sentAt: Instant.format(Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 30)),
                    parts: [.text("message \(i)", runs: [])], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
        }
        return Store(conversation: Conversation(id: "c", title: "t", participants: [], messages: messages), baseDate: Date())
    }

    @Test func anEditToBlankLinesChangesNothing() {
        let s = Self.store(3)
        s.dispatch(.edit("m1", "\n \n\t\n"))
        #expect(s.state.conversation.messages.count == 3)
    }

    @Test func anEvictionWithNegativeCountsDoesNotTrap() {
        let s = Self.store(4)
        s.dispatch(.evict(top: -1, bottom: -2))
        #expect(s.state.conversation.messages.count == 4)
        s.dispatch(.evict(top: 9, bottom: 9))
        #expect(s.state.conversation.messages.isEmpty)
    }

    static let tokens = ["```", "```swift\n", "~~~", "\n", "    ", "| a | b |\n", "|---|---|\n", "- ", "1. ", "> ", "# ", "===\n", "---\n",
                         "\"", "'", "`", "/*", "*/", "//", "#", "0.5", "x_y", "\\", "*", "_", "~~", "[a](https://b.c)", "<https://d.e>",
                         "日本", "👩‍👩‍👧‍👦", "e\u{301}", String(repeating: "y", count: 700), "\r\n", "\t"]

    @Test func randomTextThroughTheScannersDoesNotTrap() {
        var seed: UInt64 = 0xBEEF
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: (seed >> 33) % UInt64(max(1, n))) }
        for round in 0..<600 {
            let text = (0..<next(80)).map { _ in Self.tokens[next(Self.tokens.count)] }.joined()
            _ = HomeMarkdown.render(text)
            let doc = Markdown.parse("```" + ["swift", "py", "js", "sh", "sql", "css", "lua", "json"][round % 8] + "\n" + text + "\n```")
            _ = MarkdownLayoutEngine.layout(doc, source: text, maxWidth: CGFloat(40 + next(800)))
            if round % 20 == 0 {
                let long = String(repeating: text + "\n\n", count: 60)
                let index = LongTextIndex.build(long, lineage: 9300 + round, markdown: true)
                let layout = LongTextLayout(index: index, width: 500)
                layout.measureNow(0..<index.blockCount)
            }
        }
    }
}
