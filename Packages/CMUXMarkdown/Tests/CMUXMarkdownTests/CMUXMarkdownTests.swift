import Foundation
import XCTest
@testable import CMUXMarkdown

final class CMUXMarkdownTests: XCTestCase {
    func testParsesCommonBlocks() {
        let document = CMUXMarkdown.parse("""
        # Title

        Paragraph with **bold**, *emphasis*, `code`, and [link](https://example.com).

        - One
        - Two

        ```swift
        let value = 42
        ```

        | Name | Value |
        | --- | --- |
        | alpha | beta |
        """)

        XCTAssertEqual(document.blocks.count, 5)
        XCTAssertEqual(document.blocks[0], .heading(level: 1, inlines: [.text("Title")]))

        guard case let .paragraph(inlines) = document.blocks[1] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.strong([.text("bold")])))
        XCTAssertTrue(inlines.contains(.emphasis([.text("emphasis")])))
        XCTAssertTrue(inlines.contains(.code("code")))
        XCTAssertTrue(inlines.contains(.link(label: [.text("link")], destination: "https://example.com")))

        guard case let .unorderedList(items) = document.blocks[2] else {
            return XCTFail("Expected unordered list")
        }
        XCTAssertEqual(items, [[.text("One")], [.text("Two")]])

        guard case let .codeBlock(info, code) = document.blocks[3] else {
            return XCTFail("Expected code block")
        }
        XCTAssertEqual(info, "swift")
        XCTAssertEqual(code, "let value = 42")

        guard case let .table(header, rows) = document.blocks[4] else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(header, [[.text("Name")], [.text("Value")]])
        XCTAssertEqual(rows, [[[.text("alpha")], [.text("beta")]]])
    }

    func testAttributedInlineRendererPreservesWhitespaceAndSemanticRuns() throws {
        let rendered = CMUXMarkdown.attributedString(
            fromMarkdown: "**Bold**\n[Link](https://example.com) and `code`"
        )

        XCTAssertEqual(String(rendered.characters), "Bold\nLink and code")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent == .code })
        XCTAssertTrue(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    func testMalformedInlineMarkupStaysLiteral() {
        let rendered = CMUXMarkdown.attributedString(fromMarkdown: "literal [link]( and **bold")

        XCTAssertEqual(String(rendered.characters), "literal [link]( and **bold")
    }

    func testBlockQuoteAndOrderedListPlainText() {
        let document = CMUXMarkdown.parse("""
        > Quote **here**

        3. Three
        4. Four
        """)

        XCTAssertEqual(CMUXMarkdown.plainText(from: document), "Quote here\n\n3. Three\n4. Four")
    }
}
