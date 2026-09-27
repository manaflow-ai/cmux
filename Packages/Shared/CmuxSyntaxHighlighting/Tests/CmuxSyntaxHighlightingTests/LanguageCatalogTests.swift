import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite("Language catalog")
struct LanguageCatalogTests {
    private let catalog = LanguageCatalog()

    @Test("Maps common source extensions to highlight.js ids")
    func mapsCommonExtensions() {
        #expect(catalog.language(forExtension: "json") == "json")
        #expect(catalog.language(forExtension: "tsx") == "typescript")
        #expect(catalog.language(forExtension: "swift") == "swift")
        #expect(catalog.language(forExtension: "yml") == "yaml")
        #expect(catalog.language(forExtension: "TS") == "typescript")
        #expect(catalog.language(forExtension: ".py") == "python")
    }

    @Test("Unknown extensions return nil")
    func unknownExtensionIsNil() {
        #expect(catalog.language(forExtension: "bin") == nil)
        #expect(catalog.language(forExtension: "") == nil)
    }

    @Test("Resolves language from a file URL")
    func languageFromURL() {
        let url = URL(fileURLWithPath: "/tmp/example.tsx")
        #expect(catalog.language(for: url) == "typescript")
    }
}
