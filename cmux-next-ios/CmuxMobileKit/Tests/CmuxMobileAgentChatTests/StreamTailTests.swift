import CmuxMobileMarkdown
import Testing

@Suite struct StreamTailTests {
    @Test func hidesAnOpenEmphasis() {
        #expect(MarkdownStreamTail("Short answer to *Make the transport").displayed == "Short answer to Make the transport")
    }

    @Test func keepsClosedEmphasis() {
        let text = "Short answer to *Make the transport* layer"
        #expect(MarkdownStreamTail(text).displayed == text)
    }

    @Test func hidesAnOpenStrongAndCode() {
        #expect(MarkdownStreamTail("This is **bold and `code").displayed == "This is bold and code")
    }

    @Test func leavesBulletsArithmeticAndSnakeCase() {
        let text = "* item with a * b and snake_case"
        #expect(MarkdownStreamTail(text).displayed == text)
    }

    @Test func onlyTheLastBlockChanges() {
        let text = "First *para\n\nSecond *open"
        #expect(MarkdownStreamTail(text).displayed == "First *para\n\nSecond open")
    }

    @Test func leavesOpenFencesAndMath() {
        let fence = "Run:\n\n```bash\nls *"
        #expect(MarkdownStreamTail(fence).displayed == fence)
        let math = "Cost:\n\n$$\nT * x"
        #expect(MarkdownStreamTail(math).displayed == math)
    }

    @Test func markersInsideCodeSpansDoNotCount() {
        let text = "Use `a*b` then *open"
        #expect(MarkdownStreamTail(text).displayed == "Use `a*b` then open")
    }
}
