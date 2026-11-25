import CmuxHomeCore
import Foundation
import Testing

/// ``MessagePreview``: a message's Markdown as the words a preview shows (Lawrence, 2026-11-20: a reply quote of the
/// Chief's before/after table showed "| | Before | After ||---|…").
@Suite struct MessagePreviewTests {
    static let words = MessagePreview.Words(table: { "Table: \($0)" }, untitledTable: "Table", image: "Image", images: { "\($0) images" })

    static func line(_ markdown: String) -> String { MessagePreview(markdown: markdown).text(words) }

    static let beforeAfter = """
        | | Before | After |
        |---|---|---|
        | Light | ![before, light](/tmp/bl.png) | ![after, light](/tmp/al.png) |
        | Dark | ![before, dark](/tmp/bd.png) | ![after, dark](/tmp/ad.png) |
        """

    @Test func aTableIsNamedByItsTitledColumnsAndListsItsPictures() {
        let preview = MessagePreview(markdown: Self.beforeAfter)
        #expect(preview.text(Self.words) == "Table: Before / After")
        #expect(preview.tables == [MessagePreview.Table(columns: ["Before", "After"], rows: 2)])
        #expect(preview.images.map(\.source) == ["/tmp/bl.png", "/tmp/al.png", "/tmp/bd.png", "/tmp/ad.png"])
        #expect(preview.images.first?.alt == "before, light")
    }

    @Test(arguments: [
        ("| | |\n|---|---|\n| a | b |", "Table"),
        ("Shots below.\n\n| A | B |\n| :-- | --: |\n| 1 | 2 |\n\nThat's all.", "Shots below. Table: A / B That's all."),
        ("| **Step** | `Who` |\n|---|---|\n| 1 | a12 |", "Table: Step / Who"),
        ("a | b without a delimiter row", "a | b without a delimiter row"),
    ])
    func tables(_ markdown: String, _ expected: String) {
        #expect(Self.line(markdown) == expected)
    }

    @Test(arguments: [
        ("**Done.** See [PR 12](https://github.com/manaflow-ai/cmux/pull/12), run `bun test`", "Done. See PR 12, run bun test"),
        ("Shots: ![b](/tmp/b.png) and [the PR](https://example.com/pr/1)", "Shots: and the PR"),
        ("![before](/tmp/a.png)", "Image"),
        ("![before](/tmp/a.png) ![after](/tmp/b.png)", "2 images"),
        ("<https://cmux.com> and ~~gone~~ and *it* and _that_", "https://cmux.com and gone and it and that"),
        ("[![badge](https://x/b.svg) build](https://x/ci)", "build"),
    ])
    func inline(_ markdown: String, _ expected: String) {
        #expect(Self.line(markdown) == expected)
    }

    @Test(arguments: [
        ("# Heading ##\n> quoted line\n- item one\n- [x] done\n1. first\n---\nafter", "Heading quoted line item one done 1. first after"),
        ("```swift\nlet a = 1\n```\nafter the fence", "let a = 1 after the fence"),
        ("Title\n=====\nbody", "Title body"),
    ])
    func blocks(_ markdown: String, _ expected: String) {
        #expect(Self.line(markdown) == expected)
    }

    @Test(arguments: [
        "PR #12 fixes snake_case_names",
        "2*3*4 is 24, ~5 min, a * b",
        "plain words only",
        "",
    ])
    func literalTextStays(_ text: String) {
        #expect(Self.line(text) == text)
    }

    @Test func escapesShowTheirCharacter() {
        #expect(Self.line(#"a \| b \* c \_d\_"#) == "a | b * c _d_")
    }

    @Test func whiteSpaceFoldsToSingleSpaces() {
        #expect(Self.line("  two  spaces\tand a\nnewline\r\nmore  ") == "two spaces and a newline more")
    }

    /// One case of `MessagePreviewCases.json`, the file the Rust port (`cmux-message-preview`) reads too.
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        var markdown: String
        var text: String
        var images: [String]?
        var testDescription: String { markdown.debugDescription }
    }

    static let cases: [Case] = {
        struct File: Decodable { var cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("MessagePreviewCases.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.cases
    }()

    @Test func theSharedCaseFileIsRead() {
        #expect(Self.cases.count >= 20)
    }

    /// The cases both implementations must give: the Mac and iPhone previews here, the daemon's Home rows and the
    /// Chief's push in Rust.
    @Test(arguments: cases)
    func sharedCase(_ c: Case) {
        let preview = MessagePreview(markdown: c.markdown)
        #expect(preview.text(Self.words) == c.text)
        #expect(preview.images.map(\.source) == (c.images ?? []))
    }

    @Test func aLongTextIsReadInOnePassWithoutStackGrowth() {
        let long = String(repeating: "word **bold** [link](https://x) ", count: 5_000)
        #expect(Self.line(long).hasPrefix("word bold link word bold link"))
    }
}
