import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A streaming reply mapped token by token (HomeStreamMapper) gives exactly the parts the full
/// mapping gives (HomeMapping.parts, markdown), so the posted reply replaces the bubble with
/// nothing moving, while each token renders only its own lines.
@MainActor struct HomeStreamMapperTests {
    static let reply = """
    ## Plan

    Here is **what** changed, see https://example.com/a and `code`, [the PR](https://github.com/manaflow-ai/cmux/pull/123).
    - first *item*
      - nested [link](https://example.com/b)
    1. numbered

    https://example.com/card
    Trailing text\r
    a CRLF line\r\nand more

    | a | b |
    | - | - |
    | 1 | 2 |
    """

    static let fenced = reply + "\n\n```swift\nlet x = 1\n  https://example.com/in-fence\n```\nafter the fence\n~~~\ntilde\n~~~\n"

    @Test(arguments: [reply, fenced])
    func everyPrefixMapsAsTheFullMappingDoes(_ text: String) {
        let mapper = HomeStreamMapper()
        var prefix = ""
        for c in text {
            prefix.append(c)
            let want = HomeMapping.parts(.text(prefix), markdown: true)
            let got = mapper.parts(prefix, links: { _ in nil })
            #expect(got == want, "prefix of \(prefix.count) characters")
            if got != want { return }
        }
        #expect(mapper.renderer.resumes > 0, "a growing reply resumes after its kept lines")
    }

    @Test func aTextThatIsNotAnExtensionMapsInFull() {
        let mapper = HomeStreamMapper()
        _ = mapper.parts(Self.fenced, links: { _ in nil })
        let other = "# Other\nreply with **bold**\n"
        #expect(mapper.parts(other, links: { _ in nil }) == HomeMapping.parts(.text(other), markdown: true))
    }

    @Test func linesAreRenderedOnceWhileTheReplyGrows() {
        let mapper = HomeStreamMapper()
        var text = "```\n"
        for i in 0..<200 { text += "line \(i) with **bold** words\n"; _ = mapper.parts(text, links: { _ in nil }) }
        // Inside a fence lines skip the cache; outside it each distinct line renders once (plus the growing last line).
        var plain = ""
        let before = mapper.renderer.lines.renders
        for i in 0..<200 { plain += "line \(i) with **bold** words\n"; _ = mapper.parts(plain + "~~~", links: { _ in nil }) }
        #expect(mapper.renderer.lines.renders - before <= 2 * 200 + 2)
    }
}
