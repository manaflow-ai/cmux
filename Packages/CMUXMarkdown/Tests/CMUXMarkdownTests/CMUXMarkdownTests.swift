import CoreText
import XCTest
@testable import CMUXMarkdown
#if canImport(AppKit)
import AppKit
#endif

final class CMUXMarkdownTests: XCTestCase {
    func testParsesCommonBlocksAndStripsInlineMarkers() {
        let markdown = """
        # Title

        This has **strong**, *emphasis*, `code`, ~~strike~~, and [link](https://example.com).

        - [x] done
        1. numbered
        > quote

        ```swift
        let x = 1
        ```
        """

        let document = CMUXMarkdownParser().parse(markdown)

        XCTAssertEqual(document.blocks.count, 6)
        XCTAssertEqual(document.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(document.blocks[0].text, "Title")
        XCTAssertEqual(document.blocks[1].text, "This has strong, emphasis, code, strike, and link.")
        XCTAssertTrue(document.blocks[1].inlineSpans.contains { $0.styles.contains(.strong) })
        XCTAssertTrue(document.blocks[1].inlineSpans.contains { $0.styles.contains(.emphasis) })
        XCTAssertTrue(document.blocks[1].inlineSpans.contains { $0.styles.contains(.code) })
        XCTAssertTrue(document.blocks[1].inlineSpans.contains { $0.styles.contains(.strikethrough) })
        XCTAssertTrue(document.blocks[1].inlineSpans.contains { $0.styles.contains(.link) && $0.linkDestination == "https://example.com" })
        XCTAssertEqual(document.blocks[2].kind, .unorderedListItem(depth: 0, taskState: .checked))
        XCTAssertEqual(document.blocks[3].kind, .orderedListItem(depth: 0, number: 1))
        XCTAssertEqual(document.blocks[4].kind, .blockQuote(depth: 1))
        XCTAssertEqual(document.blocks[5].kind, .codeBlock(language: "swift"))
    }

    func testLongCodeFenceCanContainShorterFence() {
        let markdown = """
        ````markdown
        ```swift
        let value = true
        ```
        ````

        After
        """

        let document = CMUXMarkdownParser().parse(markdown)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].kind, .codeBlock(language: "markdown"))
        XCTAssertEqual(document.blocks[0].text, "```swift\nlet value = true\n```")
        XCTAssertEqual(document.blocks[1].text, "After")
    }

    func testHeadingPreservesLiteralTrailingHash() {
        let document = CMUXMarkdownParser().parse("""
        # C#
        ## Release notes ###
        """)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].text, "C#")
        XCTAssertEqual(document.blocks[1].text, "Release notes")
    }

    func testRendererProducesCoreTextAttributedString() {
        let rendered = CMUXMarkdownCoreTextRenderer().render("## Hello\n\nUse **bold** and `code`.")

        XCTAssertTrue(rendered.plainText.contains("Hello"))
        XCTAssertFalse(rendered.plainText.contains("**"))
        XCTAssertGreaterThan(CFAttributedStringGetLength(rendered.attributedString), 0)
    }

    func testCoreTextRendererDoesNotApplyLinkStyleToListMarkers() {
        let rendered = CMUXMarkdownCoreTextRenderer().render("""
        - [AppDelegate.swift](file:///tmp/AppDelegate.swift)
        1. [BrowserPanel.swift](file:///tmp/BrowserPanel.swift)
        """)
        let attributed = rendered.attributedString as NSAttributedString
        let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
        let firstMarkerRange = (rendered.plainText as NSString).range(of: "- ")
        let firstFilenameRange = (rendered.plainText as NSString).range(of: "AppDelegate.swift")
        let secondMarkerRange = (rendered.plainText as NSString).range(of: "1. ")
        let secondFilenameRange = (rendered.plainText as NSString).range(of: "BrowserPanel.swift")

        XCTAssertEqual(firstMarkerRange.location, 0)
        XCTAssertNil(attributed.attribute(underlineKey, at: firstMarkerRange.location, effectiveRange: nil))
        XCTAssertNotNil(attributed.attribute(underlineKey, at: firstFilenameRange.location, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(underlineKey, at: secondMarkerRange.location, effectiveRange: nil))
        XCTAssertNotNil(attributed.attribute(underlineKey, at: secondFilenameRange.location, effectiveRange: nil))
    }

    func testInlineUnderscoresInsideFilenamesStayLiteral() {
        let markdown = "Fix shell/platformdelegate_mac.mm and keep _real emphasis_ working."

        let parsed = CMUXMarkdownInlineParser().parse(markdown)

        XCTAssertEqual(parsed.text, "Fix shell/platformdelegate_mac.mm and keep real emphasis working.")
        let italicSpans = parsed.spans.filter { $0.styles.contains(.emphasis) }
        XCTAssertEqual(italicSpans.count, 1)
        XCTAssertEqual(
            italicSpans.first?.range.location,
            ("Fix shell/platformdelegate_mac.mm and keep " as NSString).length
        )
        XCTAssertFalse(parsed.spans.contains { span in
            let filenameRange = (parsed.text as NSString).range(of: "platformdelegate_mac.mm")
            return NSIntersectionRange(span.range, filenameRange).length > 0 && span.styles.contains(.emphasis)
        })
    }

    func testInlineParserPreservesLiteralBackslashes() {
        let markdown = #"Path C:\Users\me and escaped \*literal\*."#

        let parsed = CMUXMarkdownInlineParser().parse(markdown)

        XCTAssertEqual(parsed.text, #"Path C:\Users\me and escaped *literal*."#)
        XCTAssertTrue(parsed.spans.isEmpty)
    }

    func testInlineParserPreservesNestedParenthesesInLinkDestinations() throws {
        let markdown = "[Wikipedia](https://en.wikipedia.org/wiki/Foo_(bar))"

        let parsed = CMUXMarkdownInlineParser().parse(markdown)

        XCTAssertEqual(parsed.text, "Wikipedia")
        let span = try XCTUnwrap(parsed.spans.first)
        XCTAssertTrue(span.styles.contains(.link))
        XCTAssertEqual(span.linkDestination, "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func testParsesPipeTablesAsStructuredBlocks() throws {
        let markdown = """
        | Feature | Status | Notes |
        | :--- | ---: | :---: |
        | Tables | **done** | `pretty` |
        | Escaped \\| pipe | 12 | [link](https://example.com) |
        | Path | C:\\Users\\me | keep backslashes |
        """

        let document = CMUXMarkdownParser().parse(markdown)

        XCTAssertEqual(document.blocks.count, 1)
        let block = try XCTUnwrap(document.blocks.first)
        XCTAssertEqual(block.kind, .table)
        let table = try XCTUnwrap(block.table)
        XCTAssertEqual(table.alignments, [.left, .right, .center])
        XCTAssertEqual(table.rows.count, 4)
        XCTAssertEqual(table.rows[0].cells.map(\.text), ["Feature", "Status", "Notes"])
        XCTAssertEqual(table.rows[1].cells.map(\.text), ["Tables", "done", "pretty"])
        XCTAssertEqual(table.rows[2].cells.map(\.text), ["Escaped | pipe", "12", "link"])
        XCTAssertEqual(table.rows[3].cells.map(\.text), ["Path", #"C:\Users\me"#, "keep backslashes"])
        XCTAssertTrue(table.rows[0].isHeader)
        XCTAssertFalse(table.rows[1].isHeader)
    }

    func testRendererFormatsTablesWithoutRawDelimiterSyntax() {
        let markdown = """
        | Feature | Status | Notes |
        | :--- | ---: | :---: |
        | Tables | **done** | `pretty` |
        | Escaped \\| pipe | 12 | [link](https://example.com) |
        """

        let rendered = CMUXMarkdownCoreTextRenderer().render(markdown)

        XCTAssertTrue(rendered.plainText.contains("Feature"))
        XCTAssertTrue(rendered.plainText.contains("--------------+--------+------"))
        XCTAssertTrue(rendered.plainText.contains("Escaped | pipe |     12"))
        XCTAssertFalse(rendered.plainText.contains(":---"))
        XCTAssertFalse(rendered.plainText.contains("---:"))
        XCTAssertEqual(CFAttributedStringGetLength(rendered.attributedString), rendered.plainText.utf16.count)
    }

    #if canImport(AppKit)
    func testAppKitRendererUsesNativeStyledTextTables() throws {
        let markdown = """
        | Feature | Status | Notes |
        | :--- | :---: | ---: |
        | Tables | **done** | `pretty` |
        | Escaped \\| pipe | pass | [link](https://example.com) |
        """
        let theme = CMUXMarkdownAppKitTheme(
            tableHeaderBackgroundColor: .systemBlue.withAlphaComponent(0.2),
            tableRowBackgroundColor: .controlBackgroundColor,
            tableAlternateRowBackgroundColor: .windowBackgroundColor,
            tableBorderColor: .separatorColor
        )

        let rendered = CMUXMarkdownAppKitRenderer(theme: theme).render(markdown)

        var tableBlocks: [NSTextTableBlock] = []
        rendered.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            tableBlocks.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
        }

        XCTAssertEqual(tableBlocks.count, 9)
        let headerBlock = try XCTUnwrap(tableBlocks.first)
        XCTAssertEqual(headerBlock.startingRow, 0)
        XCTAssertEqual(headerBlock.startingColumn, 0)
        XCTAssertNotNil(headerBlock.backgroundColor)
        XCTAssertGreaterThan(headerBlock.width(for: .border, edge: .minX), 0)
        rendered.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { return }
            XCTAssertEqual(style.alignment, .left)
        }
        XCTAssertTrue(rendered.string.contains("Feature"))
        XCTAssertTrue(rendered.string.contains("Escaped | pipe"))
        XCTAssertFalse(rendered.string.contains(":---"))
    }

    func testAppKitRendererMarksCodeBlocksForRoundedCardDrawing() throws {
        let markdown = """
        ```swift
        final class ThingTheViewTalksTo { }
        actor ThingThatOwnsSharedBackgroundState { }
        let value = true // comment
        ```
        """
        let languageFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let theme = CMUXMarkdownAppKitTheme(
            codeBlockLanguageFont: languageFont,
            codeBlockForegroundColor: .white,
            codeBlockBackgroundColor: .black,
            codeBlockBorderColor: .gray,
            codeBlockLanguageColor: .lightGray,
            codeBlockKeywordColor: .systemBlue,
            codeBlockTypeColor: .systemRed,
            codeBlockCommentColor: .secondaryLabelColor,
            codeBlockStringColor: .systemGreen
        )

        let rendered = CMUXMarkdownAppKitRenderer(theme: theme).render(markdown)

        XCTAssertTrue(rendered.string.hasPrefix("swift\n"))
        XCTAssertTrue(rendered.string.contains("final class ThingTheViewTalksTo"))
        XCTAssertFalse(rendered.string.contains("```"))
        let fullRange = NSRange(location: 0, length: rendered.length)
        var codeBlockIDs = Set<Int>()
        rendered.enumerateAttribute(.cmuxMarkdownCodeBlockID, in: fullRange) { value, range, _ in
            guard let blockID = value as? Int else { return }
            codeBlockIDs.insert(blockID)
            XCTAssertEqual(rendered.attribute(.cmuxMarkdownCodeBlockBackgroundColor, at: range.location, effectiveRange: nil) as? NSColor, .black)
            XCTAssertEqual(rendered.attribute(.cmuxMarkdownCodeBlockBorderColor, at: range.location, effectiveRange: nil) as? NSColor, .gray)
            XCTAssertEqual(
                rendered.attribute(.cmuxMarkdownCodeBlockCopyText, at: range.location, effectiveRange: nil) as? String,
                "final class ThingTheViewTalksTo { }\nactor ThingThatOwnsSharedBackgroundState { }\nlet value = true // comment"
            )
            let paragraphStyle = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(paragraphStyle?.firstLineHeadIndent, 16)
            XCTAssertEqual(paragraphStyle?.headIndent, 16)
            XCTAssertEqual(paragraphStyle?.lineSpacing, 0)
            XCTAssertEqual(paragraphStyle?.paragraphSpacingBefore, 0)
        }
        XCTAssertEqual(codeBlockIDs.count, 1)
        let swiftRange = (rendered.string as NSString).range(of: "swift")
        let finalRange = (rendered.string as NSString).range(of: "final")
        let typeRange = (rendered.string as NSString).range(of: "ThingTheViewTalksTo")
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: swiftRange.location, effectiveRange: nil) as? NSColor, .lightGray)
        let languageRenderedFont = rendered.attribute(.font, at: swiftRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(languageRenderedFont?.pointSize, languageFont.pointSize)
        XCTAssertFalse(languageRenderedFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
        let languageParagraphStyle = rendered.attribute(.paragraphStyle, at: swiftRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(languageParagraphStyle?.paragraphSpacing, 8)
        let codeParagraphStyle = rendered.attribute(.paragraphStyle, at: finalRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(codeParagraphStyle?.paragraphSpacing, 0)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: finalRange.location, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: typeRange.location, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testAppKitRendererAddsBreathingRoomBeforeCodeBlocks() {
        let markdown = """
        Intro text.

        ```swift
        let value = true
        ```
        """

        let rendered = CMUXMarkdownAppKitRenderer().render(markdown)

        XCTAssertTrue(rendered.string.contains("Intro text.\n\nswift\n"))
    }

    func testAppKitRendererDoesNotApplyLinkStyleToListMarkers() {
        let rendered = CMUXMarkdownAppKitRenderer().render("""
        - [AppDelegate.swift](file:///tmp/AppDelegate.swift)
        1. [BrowserPanel.swift](file:///tmp/BrowserPanel.swift)
        """)
        let firstMarkerRange = (rendered.string as NSString).range(of: "- ")
        let firstFilenameRange = (rendered.string as NSString).range(of: "AppDelegate.swift")
        let secondMarkerRange = (rendered.string as NSString).range(of: "1. ")
        let secondFilenameRange = (rendered.string as NSString).range(of: "BrowserPanel.swift")

        XCTAssertEqual(firstMarkerRange.location, 0)
        XCTAssertNil(rendered.attribute(.underlineStyle, at: firstMarkerRange.location, effectiveRange: nil))
        XCTAssertNotNil(rendered.attribute(.underlineStyle, at: firstFilenameRange.location, effectiveRange: nil))
        XCTAssertNil(rendered.attribute(.underlineStyle, at: secondMarkerRange.location, effectiveRange: nil))
        XCTAssertNotNil(rendered.attribute(.underlineStyle, at: secondFilenameRange.location, effectiveRange: nil))
    }
    #endif

    func testTableParserDoesNotSplitEscapedOrCodeSpanPipes() throws {
        let markdown = """
        Key | Value
        --- | ---
        escaped | a\\|b
        code | `x|y`
        """

        let table = try XCTUnwrap(CMUXMarkdownParser().parse(markdown).blocks.first?.table)

        XCTAssertEqual(table.rows[1].cells[1].text, "a|b")
        XCTAssertEqual(table.rows[2].cells[1].text, "x|y")
    }

    func testTableRequiresDelimiterLine() {
        let markdown = """
        A | B
        not a delimiter
        """

        let document = CMUXMarkdownParser().parse(markdown)

        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].kind, .paragraph)
        XCTAssertNil(document.blocks[0].table)
    }

    func testMixedTranscriptFixtureIncludesTableListsAndCode() {
        let markdown = """
        ### Verification

        - Local `bash ./Scripts/cursor-showcase-test.sh` passed.
          - Nested item stays indented.
        1. Remote `ssh cmux-macmini` passed.

        | Check | Result | Notes |
        | --- | :---: | ---: |
        | local | pass | 1200x746 |
        | remote | pass | 1200x746 |

        > Context automatically compacted.

        ```swift
        let renderer = CMUXMarkdownCoreTextRenderer()
        ```
        """

        let document = CMUXMarkdownParser().parse(markdown)
        let rendered = CMUXMarkdownCoreTextRenderer().render(document)

        XCTAssertTrue(document.blocks.contains { $0.kind == .table })
        XCTAssertTrue(rendered.plainText.contains("Check  | Result |    Notes"))
        XCTAssertTrue(rendered.plainText.contains("------+--------+---------"))
        XCTAssertTrue(rendered.plainText.contains("- Local bash ./Scripts/cursor-showcase-test.sh passed."))
        XCTAssertTrue(rendered.plainText.contains("let renderer = CMUXMarkdownCoreTextRenderer()"))
        XCTAssertFalse(rendered.plainText.contains("| --- |"))
    }

    func testParserIsLinearEnoughForLargeTranscriptMarkdown() {
        let fixture = (0..<1_000)
            .map { index in
                """
                ### Step \(index)
                Text with **bold** and `code`.
                - item \(index)
                | Metric | Value | Notes |
                | --- | ---: | :---: |
                | local | \(index) | pass |
                """
            }
            .joined(separator: "\n")
        let start = DispatchTime.now().uptimeNanoseconds
        let document = CMUXMarkdownParser().parse(fixture)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertEqual(document.blocks.count, 4_000)
        XCTAssertEqual(document.blocks.filter { $0.kind == .table }.count, 1_000)
        XCTAssertLessThan(elapsed, 500)
    }
}
