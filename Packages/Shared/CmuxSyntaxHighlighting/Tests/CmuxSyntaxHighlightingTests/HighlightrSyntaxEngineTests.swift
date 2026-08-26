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
        #expect(result.distinctForegroundColorCount >= 2)
    }

    @Test("Applies each active theme only once")
    func appliesThemeOnlyWhenItChanges() async throws {
        let highlightr = ThemeRecordingHighlightr()
        let engine = HighlightrSyntaxEngine(themeApplying: highlightr)

        _ = try #require(
            await engine.highlight(text: #"{"a":1}"#, language: "json", theme: .dark)
        )
        _ = try #require(
            await engine.highlight(text: #"{"b":2}"#, language: "json", theme: .dark)
        )
        _ = try #require(
            await engine.highlight(text: #"{"c":3}"#, language: "json", theme: .light)
        )

        #expect(highlightr.appliedThemeNames == ["xcode-dark", "xcode"])
    }

    @Test("Does not cache a failed theme application")
    func retriesThemeAfterApplicationFailure() async throws {
        let highlightr = ThemeRecordingHighlightr(themeApplicationResults: [false, true])
        let engine = HighlightrSyntaxEngine(themeApplying: highlightr)

        let failed = await engine.highlight(
            text: #"{"a":1}"#,
            language: "json",
            theme: .dark
        )
        let succeeded = await engine.highlight(
            text: #"{"b":2}"#,
            language: "json",
            theme: .dark
        )

        #expect(failed == nil)
        #expect(try #require(succeeded).value.string == #"{"b":2}"#)
        #expect(highlightr.appliedThemeNames == ["xcode-dark", "xcode-dark"])
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

/// Test fake is used serially through ``HighlightrSyntaxEngine``'s actor.
private final class ThemeRecordingHighlightr: HighlightrThemeApplying, @unchecked Sendable {
    private(set) var appliedThemeNames: [String] = []
    private var themeApplicationResults: [Bool]

    init(themeApplicationResults: [Bool] = []) {
        self.themeApplicationResults = themeApplicationResults
    }

    func setTheme(to name: String) -> Bool {
        appliedThemeNames.append(name)
        return themeApplicationResults.isEmpty ? true : themeApplicationResults.removeFirst()
    }

    func highlight(_ text: String, as language: String?) -> NSAttributedString? {
        NSAttributedString(string: text)
    }
}
