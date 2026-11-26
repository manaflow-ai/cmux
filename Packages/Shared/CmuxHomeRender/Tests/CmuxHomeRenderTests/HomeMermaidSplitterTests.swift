import CmuxHomeRender
import Testing

/// Mermaid fences in a Home message become diagram pieces; everything else stays text as written.
@Suite struct HomeMermaidSplitterTests {
    let splitter = HomeMermaidSplitter()

    /// Joining every piece gives the text back, so nothing a sender wrote is lost.
    func roundTrips(_ text: String) -> [HomeTextSegment] {
        let segments = splitter.segments(in: text)
        #expect(segments.map(\.original).joined() == text)
        return segments
    }

    @Test func textBeforeAndAfterAFenceStaysText() {
        let segments = roundTrips("Here is the flow:\n```mermaid\ngraph TD\nA-->B\n```\nThat is all.")
        #expect(segments == [
            .text("Here is the flow:\n"),
            .mermaid(source: "graph TD\nA-->B", fenced: "```mermaid\ngraph TD\nA-->B\n```"),
            .text("\nThat is all."),
        ])
    }

    @Test func everyFenceIsItsOwnDiagram() {
        let segments = roundTrips("```mermaid\ngraph TD\nA-->B\n```\n```mermaid\nsequenceDiagram\nA->>B: hi\n```\nend")
        let sources = segments.compactMap { if case .mermaid(let source, _) = $0 { source } else { nil } }
        #expect(sources == ["graph TD\nA-->B", "sequenceDiagram\nA->>B: hi"])
        #expect(segments.last == .text("\nend"))
    }

    @Test(arguments: [
        "```swift\nlet x = 1\n```\nplain",
        "````markdown\n```mermaid\ngraph TD\n```\n````",
        "    ```mermaid\n    graph TD\n    ```",
        "a mermaid is a sea creature",
    ])
    func otherFencesAndIndentedCodeStayText(_ text: String) {
        #expect(roundTrips(text) == [.text(text)])
    }

    @Test func anUnclosedFenceStaysText() {
        let streaming = "Drawing it:\n```mermaid\ngraph TD\nA-->B"
        #expect(roundTrips(streaming) == [.text(streaming)])
    }

    @Test func tildesInfoWordsCaseAndIndentation() {
        let segments = roundTrips("  ~~~ Mermaid {theme}\r\n  graph LR\r\n    A-->B\r\n  ~~~~\r\nok")
        #expect(segments.first == .mermaid(source: "graph LR\n  A-->B", fenced: "  ~~~ Mermaid {theme}\r\n  graph LR\r\n    A-->B\r\n  ~~~~\r"))
        #expect(segments.last == .text("\nok"))
    }

    @Test func aShorterOrDifferentFenceDoesNotClose() {
        let segments = roundTrips("````mermaid\ngraph TD\n```\n~~~~\nA-->B\n````")
        #expect(segments == [.mermaid(source: "graph TD\n```\n~~~~\nA-->B", fenced: "````mermaid\ngraph TD\n```\n~~~~\nA-->B\n````")])
    }

    @Test func emptyTextHasNoPieces() {
        #expect(splitter.segments(in: "").isEmpty)
    }
}
