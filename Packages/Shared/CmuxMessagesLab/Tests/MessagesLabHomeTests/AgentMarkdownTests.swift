import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// An agent's reply is Markdown (the Chief answers with `**headings**`, `- `
/// lists and backticks): its bubble shows the styled text, measured with the
/// same attributed text it draws. A person's message stays plain text.
@MainActor @Suite struct AgentMarkdownTests {
    let me = Fixture2.me, them = Fixture2.them

    private func textPart(_ author: ParticipantID, _ text: String) throws -> (String, [TextRun]) {
        let message = HomeMapping.message(Fixture2.item(1, author, text), aliases: [:], me: me, summary: Fixture2.summary(lastSeq: 1))
        guard case let .text(t, runs) = try #require(message.parts.first) else {
            Issue.record("not a text part"); return ("", [])
        }
        return (t, runs)
    }

    private func run(_ runs: [TextRun], _ text: String, covering word: String) -> TextRun? {
        let r = (text as NSString).range(of: word)
        return runs.first { $0.start == r.location && $0.length == r.length }
    }

    @Test func anAgentReplyShowsStyledTextNotMarkers() throws {
        let source = "**Code and files**\n- Read, write\n- Run `gh` now\n\n1. First *step*\nSee [the docs](https://cmux.com)."
        let (text, runs) = try textPart(them, source)
        #expect(text == "Code and files\n• Read, write\n• Run gh now\n\n1. First step\nSee the docs.")
        #expect(run(runs, text, covering: "Code and files")?.style == ["bold"])
        #expect(run(runs, text, covering: "gh")?.style == ["code"])
        #expect(run(runs, text, covering: "step")?.style == ["italic"])
        #expect(run(runs, text, covering: "the docs")?.link == "https://cmux.com")
    }

    @Test func aFencedCodeBlockDrawsMonospacedWithoutItsFences() throws {
        let (text, runs) = try textPart(them, "Run:\n```sh\nmake test\n```\nDone.")
        #expect(text == "Run:\nmake test\nDone.")
        #expect(run(runs, text, covering: "make test")?.style == ["code"])
        let tl = TextLayout.make(text, runs: runs, maxWidth: 300)
        let attr = tl.attributed(color: .white, linkColor: .white)
        let font = try #require(attr.attribute(.font, at: (text as NSString).range(of: "make").location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func onlyWebAndMailLinksBecomeLinks() throws {
        let (text, runs) = try textPart(them, "[open](javascript:alert(1)) and [mail](mailto:a@b.c)")
        #expect(text == "open and mail")
        #expect(runs.contains { $0.link?.hasPrefix("javascript") == true } == false)
        #expect(run(runs, text, covering: "mail")?.link == "mailto:a@b.c")
    }

    @Test func myMessageStaysPlainText() throws {
        let source = "**not bold** and `not code`\n- not a list"
        let (text, runs) = try textPart(me, source)
        #expect(text == source)
        #expect(runs.isEmpty)
    }

    @Test func plainAgentTextIsUnchanged() throws {
        let source = "Hello again! What would you like to work on? 3 * 4 = 12, snake_case_name stays."
        let (text, runs) = try textPart(them, source)
        #expect(text == source)
        #expect(runs.isEmpty)
    }

    /// Row heights stay exact: the lines are broken with the fonts they are
    /// drawn with, so no drawn bold line is wider than the measured column.
    @Test func boldLinesAreMeasuredWithTheFontTheyDrawWith() {
        let words = Array(repeating: "Wide bold words wrap here", count: 12).joined(separator: " ")
        let runs = [TextRun(start: 0, length: (words as NSString).length, style: ["bold"], link: nil, mention: nil, detected: nil)]
        let maxWidth: CGFloat = 220
        let tl = TextLayout.make(words, runs: runs, maxWidth: maxWidth)
        let drawn = tl.attributed(color: .white, linkColor: .white, kern: 0)
        for line in tl.lines {
            let ct = CTLineCreateWithAttributedString(drawn.attributedSubstring(from: line.range))
            let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(ct))
            #expect(width <= maxWidth + 0.5, "a drawn line is \(width) pt in a \(maxWidth) pt column")
            #expect(abs(width - (line.width - CGFloat(CTLineGetTrailingWhitespaceWidth(ct)))) < 0.5, "measured and drawn widths agree")
        }
    }
}
