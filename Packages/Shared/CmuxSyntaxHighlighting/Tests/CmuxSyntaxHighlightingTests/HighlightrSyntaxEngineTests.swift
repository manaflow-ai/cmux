import CmuxSyntaxHighlighting
import Testing

@Suite("Highlightr syntax engine")
struct HighlightrSyntaxEngineTests {
    @Test("JSON tokens use more than one foreground color")
    func jsonHasMultipleTokenColors() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        {
          "name": "cmux",
          "count": 3,
          "enabled": true
        }
        """
        let highlighted = await engine.highlight(
            text: source,
            language: "json",
            theme: .dark
        )
        let result = try #require(highlighted)
        #expect(result.value.string == source)
        #expect(result.distinctForegroundColorCount >= 2)
    }

    @Test("Policy rejection returns nil without coloring")
    func policyRejectionReturnsNil() async {
        let engine = HighlightrSyntaxEngine()
        let highlighted = await engine.highlight(
            text: #"{"a":1}"#,
            language: nil,
            theme: .light
        )
        #expect(highlighted == nil)
    }
}
