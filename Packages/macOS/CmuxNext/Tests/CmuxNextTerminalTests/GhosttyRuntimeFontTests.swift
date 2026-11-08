@testable import CmuxNextTerminal
import CoreText
import Foundation
import GhosttyNextKit
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

    @Test func quotedFallbackFamilyNamesRemainValidConfigValues() {
        let lines = GhosttyRuntime.fontOverrideLines(
            .init(family: "Font #1"), fallbackFamilies: ["Mono = Wide", "Quote \"Mono\""]
        )
        #expect(lines.contains("font-family = \"Font #1\""))
        #expect(lines.contains("font-family = \"Mono = Wide\""))
        #expect(lines.contains("font-family = \"Quote \\\"Mono\\\"\""))
    }

    @Test func finalizedLoadedFilesIncludeThemeFallbackFamilies() throws {
        _ = GhosttyRuntime.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "font-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let theme = directory.appending(path: "theme")
        let config = directory.appending(path: "config")
        try "font-family = \"Theme Mono\"\n".write(to: theme, atomically: true, encoding: .utf8)
        try "theme = \(theme.path)\n".write(to: config, atomically: true, encoding: .utf8)

        let loaded = try #require(ghostty_config_new())
        defer { ghostty_config_free(loaded) }
        ghostty_config_load_file(loaded, config.path)
        ghostty_config_load_recursive_files(loaded)
        let files = GhosttyRuntime.finalizedLoadedFiles(of: loaded)
        #expect(files.contains(theme.path))
        #expect(GhosttyConfigFontFamily.families(inFiles: files) == ["Theme Mono"])
    }

    @Test func glyphProbeReportsTheFixedPromptSamples() {
        let probe = GhosttyGlyphWidthProbe(family: "Menlo", size: 13, fallbackFamilies: ["Symbols Nerd Font Mono", "Noto Sans Mono CJK JP"])
        #expect(probe.measurements.map(\.sample.name) == ["ASCII", "CJK", "Nerd Font", "Emoji"])
        #expect(probe.measurements.allSatisfy { $0.cellWidth > 0 && $0.advance.isFinite })
        #expect(probe.measurements.allSatisfy { $0.sample.expectedCells > 0 })
        #expect(probe.measurements.allSatisfy { $0.cellDelta.isFinite })
        #expect(probe.measurements.dropFirst().allSatisfy { !$0.sample.text.isEmpty })
        let available = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        let configuredFallbacksInstalled = GhosttyRuntime.knownFallbackFamilies.allSatisfy(available.contains)
        if configuredFallbacksInstalled {
            #expect(probe.allSamplesMatchCellGrid)
            #expect(probe.measurements.allSatisfy { !$0.missingGlyph })
        }
    }

    @Test func glyphProbeCellGridDecisionCatchesMissingOrOverflowingFixtures() {
        let sample = GhosttyGlyphWidthProbe.Sample(name: "fixture", text: "x", expectedCells: 1)
        let aligned = GhosttyGlyphWidthProbe.Measurement(sample: sample, cellWidth: 8, advance: 8, missingGlyph: false)
        let overflowing = GhosttyGlyphWidthProbe.Measurement(sample: sample, cellWidth: 8, advance: 20, missingGlyph: false)
        let missing = GhosttyGlyphWidthProbe.Measurement(sample: sample, cellWidth: 8, advance: 8, missingGlyph: true)
        #expect(aligned.matchesCellGrid)
        #expect(overflowing.overflowsCellGrid)
        #expect(!overflowing.matchesCellGrid)
        #expect(!missing.matchesCellGrid)
    }
}
