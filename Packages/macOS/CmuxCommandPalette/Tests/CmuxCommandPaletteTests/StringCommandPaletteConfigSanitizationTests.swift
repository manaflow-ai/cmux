import Testing

@testable import CmuxCommandPalette

@Suite("String.cmuxConfigPaletteSanitized")
struct StringCommandPaletteConfigSanitizationTests {
    @Test("strips bidirectional control and zero-width scalars")
    func stripsDangerousScalars() {
        let input = "a\u{202E}b\u{200B}c\u{FEFF}\u{2069}"
        #expect(input.cmuxConfigPaletteSanitized == "abc")
    }

    @Test("trims surrounding whitespace and newlines")
    func trimsWhitespace() {
        #expect("  hello \n".cmuxConfigPaletteSanitized == "hello")
    }

    @Test("filtering before trimming yields empty for control-only input")
    func controlOnlyBecomesEmpty() {
        #expect("\u{200E}\u{200F}  ".cmuxConfigPaletteSanitized == "")
    }

    @Test("preserves ordinary unicode text")
    func preservesOrdinaryText() {
        #expect("ワークスペース".cmuxConfigPaletteSanitized == "ワークスペース")
    }
}
