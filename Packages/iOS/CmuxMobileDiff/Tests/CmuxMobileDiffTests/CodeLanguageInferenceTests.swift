import Testing

@testable import CmuxMobileDiff

@Suite struct CodeLanguageInferenceTests {
    @Test func mapsCommonExtensionsAndSpecialFilenames() {
        let inference = CodeLanguageInference()
        #expect(inference.language(for: "Sources/App.swift") == "swift")
        #expect(inference.language(for: "web/view.tsx") == "typescript")
        #expect(inference.language(for: "Dockerfile") == "dockerfile")
        #expect(inference.language(for: "Makefile") == "makefile")
    }

    @Test func unknownAndPlainTextStayUnhighlighted() {
        let inference = CodeLanguageInference()
        #expect(inference.language(for: "README") == nil)
        #expect(inference.language(for: "notes.txt") == nil)
    }
}
