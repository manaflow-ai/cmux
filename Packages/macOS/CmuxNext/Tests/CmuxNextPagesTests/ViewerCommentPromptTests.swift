import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// A viewer page's selection reply becomes a quote, and the Comment… dialog sets its comment
/// (viewer-comments-DESIGN.md).
@MainActor
struct ViewerCommentPromptTests {
    @Test func aSelectionReplyWithLinesIsAQuote() throws {
        let reply: JSONValue = ["text": "let x = 1", "startLine": 4, "endLine": 6]
        let quote = try #require(ChatQuote(selection: reply, source: "/r/a.swift", kind: .code))
        #expect(quote == ChatQuote(source: "/r/a.swift", kind: .code, lines: 4...6, quoted: "let x = 1"))
    }

    @Test func aReplyWithoutLinesKeepsTheText() throws {
        let quote = try #require(ChatQuote(selection: ["text": "hello"], source: "/r/a.md", kind: .markdown))
        #expect(quote.lines == nil)
        #expect(quote.title == "a.md")
    }

    @Test func noSelectionIsNoQuote() {
        #expect(ChatQuote(selection: .null, source: "/r/a.md", kind: .markdown) == nil)
        #expect(ChatQuote(selection: ["text": "  \n"], source: "/r/a.md", kind: .markdown) == nil)
    }

    @Test func addToChatSetsTheCommentAndCancelDropsIt() {
        let prompt = ViewerCommentPrompt(quote: ChatQuote(source: "/r/a.md", kind: .markdown, lines: 2...2, quoted: "x"))
        #expect(prompt.spec.title == ViewerSelectionMenu.Titles.commentOn("a.md · L2"))
        #expect(prompt.spec.defaultButton?.id == ViewerCommentPrompt.add)
        let added = prompt.quote(for: CmuxDialogAnswer(button: ViewerCommentPrompt.add, role: .default,
                                                       values: [ViewerCommentPrompt.field: .text("  Why? \n")]))
        #expect(added?.comment == "Why?")
        #expect(prompt.quote(for: CmuxDialogAnswer(button: "cancel", role: .cancel)) == nil)
    }
}
