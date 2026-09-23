import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct WorkstreamFullTextTests {
    @Test("Reading a completed turn retains its final paragraph and line breaks")
    func fullCompletion() throws {
        let text = String(repeating: "A paragraph with Unicode 👩🏽‍💻.\n\n", count: 1_000) + "THE END"
        let item = WorkstreamItem(workstreamId: "codex-session", source: .codex,
                                  kind: .stop, payload: .stop(reason: text))
        #expect(item.fullText == text)
        var output = ""
        var offset = 0
        repeat {
            let page = try #require(WorkstreamTextPage(text: item.fullText, offset: offset))
            #expect(page.text.utf8.count <= 16_384)
            output += page.text
            guard let next = page.nextOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(output == text)
    }

    @Test("Invalid cursors fail, including offsets inside a Unicode scalar")
    func invalidOffsets() {
        #expect(WorkstreamTextPage(text: "👋", offset: -1) == nil)
        #expect(WorkstreamTextPage(text: "👋", offset: 1) == nil)
        #expect(WorkstreamTextPage(text: "👋", offset: 5) == nil)
        #expect(WorkstreamTextPage(text: "", offset: 0)?.text == "")
    }

    @Test("Older completion rows retain the available assistant context")
    func completionContext() {
        let item = WorkstreamItem(workstreamId: "codex-session", source: .codex,
                                  kind: .stop, payload: .stop(reason: nil),
                                  context: WorkstreamContext(assistantPreamble: "The saved response"))
        #expect(item.fullText == "The saved response")
    }
}
