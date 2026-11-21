@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite("Highlightr theme adapter")
struct HighlightrThemeAdapterTests {
    @Test("A grammar that fails to register leaves its files uncolored")
    func unregisteredGrammarSkipsAutoDetection() throws {
        let broken = HighlightGrammar(name: "broken", definitionScript: "function (")
        let adapter = try #require(HighlightrThemeAdapter(grammars: [broken]))

        // Without the guard Highlightr falls back to highlightAuto and returns
        // a guessed-language result for this JSON-looking text.
        #expect(adapter.highlight(#"{"a": 1}"#, as: "broken") == nil)
        #expect(adapter.highlight(#"{"a": 1}"#, as: "json") != nil)
    }

    @Test("Bundled grammars register alongside Highlightr's languages")
    func bundledGrammarRegisters() throws {
        let adapter = try #require(HighlightrThemeAdapter())
        #expect(adapter.highlight("resource \"a\" \"b\" {}", as: "hcl") != nil)
    }
}
