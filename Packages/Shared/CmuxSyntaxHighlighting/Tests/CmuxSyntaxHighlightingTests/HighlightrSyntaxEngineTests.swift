@testable import CmuxSyntaxHighlighting
import Foundation
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
        #expect(distinctForegroundColors(in: result.value).count >= 2)
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

    private func distinctForegroundColors(in value: NSAttributedString) -> Set<String> {
        var colors: Set<String> = []
        let full = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(.foregroundColor, in: full, options: []) { attribute, _, _ in
            guard let attribute,
                  let hex = HighlightColorRemapper(theme: .dark).hexKey(from: attribute) else {
                return
            }
            colors.insert(hex)
        }
        return colors
    }
}
