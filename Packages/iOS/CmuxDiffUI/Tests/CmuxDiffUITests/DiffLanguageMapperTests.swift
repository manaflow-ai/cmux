import Testing
@testable import CmuxDiffUI

@Suite struct DiffLanguageMapperTests {
    @Test(arguments: [
        ("Sources/App.swift", "swift"),
        ("web/view.tsx", "typescript"),
        ("config/settings.json", "json"),
        ("scripts/reload.sh", "bash"),
        ("Dockerfile", "dockerfile"),
        ("Package.swift", "swift"),
        ("README.md", "markdown"),
    ])
    func mapsKnownFilenames(filename: String, expected: String) {
        #expect(DiffLanguageMapper().language(for: filename) == expected)
    }

    @Test func returnsNilForUnknownExtension() {
        #expect(DiffLanguageMapper().language(for: "Assets/blob.cmuxunknown") == nil)
    }
}
