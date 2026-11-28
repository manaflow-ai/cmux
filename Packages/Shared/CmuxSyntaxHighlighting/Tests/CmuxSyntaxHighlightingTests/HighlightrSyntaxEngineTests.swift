@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("Highlightr syntax engine")
struct HighlightrSyntaxEngineTests {
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

#if canImport(AppKit)
    @Test("SQL containing Jinja delimiters still highlights SQL tokens")
    func sqlContainingJinjaDelimitersStillHighlightsTokens() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        select id, name
        from {{ ref('users') }}
        where active = true
        """

        let highlighted = try #require(
            await engine.highlight(text: source, language: "sql", theme: .dark)
        )
        let selectRange = (highlighted.value.string as NSString).range(of: "select")
        #expect(selectRange.location != NSNotFound)
        let color = highlighted.value.attribute(
            .foregroundColor,
            at: selectRange.location,
            effectiveRange: nil
        )
        #expect(
            HighlightColorRemapper(theme: .dark).hexKey(from: color as Any) == "0091FF"
        )
    }
#endif

}
