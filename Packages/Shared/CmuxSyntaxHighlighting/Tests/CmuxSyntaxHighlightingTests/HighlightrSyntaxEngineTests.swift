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

    @Test(
        "Terraform source is tokenized by the bundled HCL grammar",
        arguments: [
            ("// Logs bucket", TokenRole.comment),
            ("resource", TokenRole.keyword),
            ("\"logs\"", TokenRole.string),
            ("versioning", TokenRole.attribute),
            // Function calls use the `title` scope, which the Xcode themes
            // paint like numbers.
            ("upper", TokenRole.number),
            ("true", TokenRole.keyword),
        ]
    )
    func terraformUsesHCLGrammar(token: String, role: TokenRole) async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        // Logs bucket
        resource "google_storage_bucket" "logs" {
          name       = upper(var.name)
          versioning = true
        }
        """

        let highlighted = try #require(
            await engine.highlight(text: source, language: "hcl", theme: .dark)
        )
        let range = (highlighted.value.string as NSString).range(of: token)
        #expect(range.location != NSNotFound)
        let color = highlighted.value.attribute(
            .foregroundColor,
            at: range.location,
            effectiveRange: nil
        )
        #expect(
            HighlightColorRemapper(theme: .dark).hexKey(from: color as Any)
                == TokenTheme.dark.palette.color(for: role).hexKey
        )
    }
#endif

}
