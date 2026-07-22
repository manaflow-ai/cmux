import Testing
@testable import CmuxArtifacts

@Suite("Artifact terminal text sanitizer")
struct ArtifactTerminalTextSanitizerTests {
    @Test("C0 and C1 controls become visible replacement characters")
    func replacesTerminalControls() {
        let unsafe = "safe\u{0}\u{7}\r\n\u{1B}\u{7F}\u{85}\u{9B}text"

        let sanitized = ArtifactTerminalTextSanitizer().sanitize(unsafe)

        #expect(sanitized == "safe��������text")
        #expect(!sanitized.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
        })
    }

    @Test("Ordinary Unicode text is unchanged")
    func preservesOrdinaryText() {
        let text = "計画/launch-plan.md — résumé"

        #expect(ArtifactTerminalTextSanitizer().sanitize(text) == text)
    }
}
