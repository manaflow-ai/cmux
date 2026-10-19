import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct AgentMarkdownDocumentTests {
    @Test func paragraphsHeadingsAndListsRemainSeparate() {
        let document = AgentMarkdownDocument(markdown: """
        ## Review

        First paragraph with **emphasis**.

        Another paragraph.

        1. Verify input
        2. Run tests
        """)
        #expect(document.blocks.count == 5)
        #expect(document.blocks.first?.kind == .heading(2))
        #expect(document.blocks.suffix(2).map(\.listMarker) == ["1.", "2."])
        #expect(document.blocks.contains { block in
            block.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        })
    }

    @Test func codeKeepsLanguageIndentationAndLineBreaks() throws {
        let document = AgentMarkdownDocument(markdown: """
        ```swift
        if ready {
            run()
        }
        ```
        """)
        let block = try #require(document.blocks.first)
        #expect(block.kind == .code("swift"))
        #expect(String(block.text.characters).contains("if ready {\n    run()\n}"))
    }

    @Test func tableCellsKeepTheirRowsAndColumns() throws {
        let document = AgentMarkdownDocument(markdown: """
        | Provider | State |
        | --- | --- |
        | Claude | Ready |
        | Codex | Working |
        """)
        let table = try #require(document.blocks.first)
        #expect(table.kind == .table)
        #expect(table.rows.map { $0.map { String($0.characters) } } == [
            ["Provider", "State"], ["Claude", "Ready"], ["Codex", "Working"],
        ])
    }

    @Test func nestedListsAndQuotedLinksRetainTheirMeaning() {
        let document = AgentMarkdownDocument(markdown: """
        - Parent
          - Child

        > See [documentation](https://example.com/docs).
        """)
        #expect(document.blocks.map(\.listDepth).prefix(2) == [1, 2])
        #expect(document.blocks.last?.isQuote == true)
        #expect(document.blocks.last?.text.runs.contains { $0.link?.absoluteString == "https://example.com/docs" } == true)
    }
}
