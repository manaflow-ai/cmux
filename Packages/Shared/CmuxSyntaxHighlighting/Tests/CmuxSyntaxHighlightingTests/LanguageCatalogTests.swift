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

    @Test("Maps BEAM source extensions to highlight.js ids")
    func mapsBeamExtensions() {
        #expect(catalog.language(forExtension: "ex") == "elixir")
        #expect(catalog.language(forExtension: "exs") == "elixir")
        #expect(catalog.language(forExtension: "erl") == "erlang")
        #expect(catalog.language(forExtension: "hrl") == "erlang")
    }

    @Test("Maps Terraform and HCL extensions to the bundled hcl grammar", arguments: ["tf", "tfvars", "hcl", "tofu", "TF"])
    func mapsHCLExtensions(fileExtension: String) {
        #expect(catalog.language(forExtension: fileExtension) == "hcl")
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
