import Testing
@testable import CmuxAcpmux

struct MarkdownBlockParserTests {
    @Test func parsesCommonBlocks() {
        let blocks = MarkdownBlockParser().parse("""
        # Title
        Some **bold** text
        continues here.

        - one
          - nested
        2. two
        > quoted
        ---
        ```swift
        let x = 1
        ```
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\ncontinues here."),
            .listItem(marker: "•", depth: 0, text: "one"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .listItem(marker: "2.", depth: 0, text: "two"),
            .quote("quoted"),
            .rule,
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    @Test func unterminatedFenceStreamsAsCode() {
        let blocks = MarkdownBlockParser().parse("Run:\n```sh\nls -la\ncd /tm")
        #expect(blocks == [.paragraph("Run:"), .code(language: "sh", text: "ls -la\ncd /tm")])
    }
}
