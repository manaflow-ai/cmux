import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact Markdown document")
struct ChatArtifactMarkdownDocumentTests {
    @Test("preserves headings paragraphs lists code and table rows as distinct blocks")
    func documentStructure() {
        let document = ChatArtifactMarkdownDocument(markdown: """
        # Guide

        Intro with **bold** text.

        - one
        2. two

        ```swift
        print("hi")
        ```

        | kind | file |
        | --- | --- |
        | log | build.log |
        | data | data.csv |
        """)

        #expect(document.blocks.map(\.kind) == [
            .heading(level: 1),
            .paragraph,
            .bullet(indent: 0),
            .ordered(marker: "2.", indent: 0),
            .code(language: "swift"),
            .tableRow(isHeader: true),
            .tableRow(isHeader: false),
            .tableRow(isHeader: false),
        ])
        #expect(document.blocks[0].text == "Guide")
        #expect(document.blocks[4].text == "print(\"hi\")")
        #expect(document.blocks[5].text == "kind │ file")
        #expect(document.blocks[7].text == "data │ data.csv")
    }
}
