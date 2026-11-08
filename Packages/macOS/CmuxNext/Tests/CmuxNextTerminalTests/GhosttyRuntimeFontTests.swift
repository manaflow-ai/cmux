@testable import CmuxNextTerminal
import Foundation
import Testing

struct GhosttyRuntimeFontTests {
    @Test func selectedFamilyComesFirstAndPreservesConfiguredFallbacks() {
        let lines = GhosttyRuntime.fontOverrideLines(
            .init(family: "Iosevka", size: 13.25),
            fallbackFamilies: ["Menlo", "Iosevka", "Symbols Nerd Font Mono"]
        )
        #expect(lines == [
            "font-family = \"\"",
            "font-family = \"Iosevka\"",
            "font-family = \"Menlo\"",
            "font-family = \"Symbols Nerd Font Mono\"",
            "font-family = \"Noto Sans Mono CJK JP\"",
            "font-size = 13.25",
        ])
    }

    @Test func configLineInjectionIsRejectedWithoutDroppingSize() {
        let lines = GhosttyRuntime.fontOverrideLines(.init(family: "Iosevka\nfont-size = 1", size: 14))
        #expect(lines == ["font-size = 14"])
    }

    @Test func glyphProbeReportsTheFixedPromptSamples() {
        let probe = GhosttyGlyphWidthProbe(family: "Menlo", size: 13, fallbackFamilies: ["Symbols Nerd Font Mono", "Noto Sans Mono CJK JP"])
        #expect(probe.measurements.map(\.sample.name) == ["ASCII", "CJK", "Nerd Font", "Emoji"])
        #expect(probe.measurements.allSatisfy { $0.cellWidth > 0 && $0.advance.isFinite })
        #expect(probe.measurements.allSatisfy { $0.sample.expectedCells > 0 })
        #expect(probe.measurements.allSatisfy { $0.matchesCellGrid })
        #expect(probe.measurements.allSatisfy { !$0.missingGlyph })
    }
}
