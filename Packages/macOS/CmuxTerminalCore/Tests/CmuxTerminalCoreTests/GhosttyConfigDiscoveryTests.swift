import Foundation
import CoreText
import Testing
@testable import CmuxTerminalCore

/// In-memory ``GhosttyConfigFileReading`` fake driven by a path -> contents map.
private struct FakeFileReader: GhosttyConfigFileReading {
    var contentsByPath: [String: String] = [:]

    func fileSize(atPath path: String) -> Int? {
        guard let contents = contentsByPath[path] else { return nil }
        return contents.lengthOfBytes(using: .utf8)
    }

    func contents(atPath path: String) -> String? {
        contentsByPath[path]
    }
}

/// Font probe fake that resolves nothing, so coverage filtering is bypassed.
private struct NoFontProbe: GhosttyFontProbing {
    func discoveredFont(named _: String, size _: CGFloat, weightTrait _: CGFloat?) -> CTFont? { nil }
    func configuredFont(named _: String, size _: CGFloat) -> CTFont? { nil }
}

@Suite struct GhosttyConfigDiscoveryCJKTests {
    private let discovery = GhosttyConfigDiscovery(fileReader: FakeFileReader(), fontProbe: NoFontProbe())

    @Test func japaneseMapsKanaAndSharedRanges() throws {
        let mappings = try #require(discovery.cjkFontMappings(preferredLanguages: ["ja-JP", "en-US"]))
        let fonts = Set(mappings.map(\.1))
        #expect(fonts == ["Hiragino Sans"])
        let ranges = Set(mappings.map(\.0))
        #expect(ranges.isSuperset(of: GhosttyConfigDiscovery.sharedCJKRanges))
        #expect(ranges.isSuperset(of: GhosttyConfigDiscovery.japaneseRanges))
    }

    @Test func koreanOnlyYieldsNoMappings() {
        #expect(discovery.cjkFontMappings(preferredLanguages: ["ko-KR"]) == nil)
    }

    @Test func traditionalChineseUsesPingFangTC() throws {
        let mappings = try #require(discovery.cjkFontMappings(preferredLanguages: ["zh-Hant-TW"]))
        #expect(Set(mappings.map(\.1)) == ["PingFang TC"])
    }

    @Test func simplifiedChineseUsesPingFangSC() throws {
        let mappings = try #require(discovery.cjkFontMappings(preferredLanguages: ["zh-Hans-CN"]))
        #expect(Set(mappings.map(\.1)) == ["PingFang SC"])
    }

    @Test func sharedRangesCoveredOnlyOnceByFirstLanguage() throws {
        let mappings = try #require(discovery.cjkFontMappings(preferredLanguages: ["ja-JP", "zh-Hans-CN"]))
        let sharedForJa = mappings.filter { GhosttyConfigDiscovery.sharedCJKRanges.contains($0.0) }
        #expect(sharedForJa.allSatisfy { $0.1 == "Hiragino Sans" })
    }

    @Test func autoInjectedCJKFontMappingsFailsClosedWhenFontCannotBeProbed() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = Some Unresolvable Font",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.autoInjectedCJKFontMappings(
            preferredLanguages: ["ja-JP"],
            configPaths: [path]
        ) == nil)
    }
}

@Suite struct GhosttyConfigDiscoverySymbolTests {
    private let discovery = GhosttyConfigDiscovery(fileReader: FakeFileReader(), fontProbe: NoFontProbe())

    @Test func symbolFontMappingsCoverAllSymbolCodepoints() {
        let mappings = discovery.symbolFontMappings()
        // A literal expected set (rather than one derived from
        // GhosttyConfigDiscovery.symbolCodepoints) so this test still catches
        // the production list being wrong or incomplete.
        let expected: Set<String> = ["U+25A0", "U+25B0", "U+25B1", "U+25CB", "U+25CF", "U+2B21", "U+2B22"]
        #expect(mappings.count == expected.count)
        #expect(Set(mappings.map(\.0)) == expected)
        #expect(mappings.allSatisfy { $0.1 == GhosttyConfigDiscovery.symbolFallbackFont })
    }

    @Test func autoInjectedSymbolFontMappingsSkipsWhenCodepointMapPresent() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-codepoint-map = U+4E00-U+9FFF=Foo",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.autoInjectedSymbolFontMappings(configPaths: [path]) == nil)
    }

    @Test func autoInjectedSymbolFontMappingsSkipsWhenExplicitFallbackChainPresent() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = JetBrains Mono\nfont-family = Menlo",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.autoInjectedSymbolFontMappings(configPaths: [path]) == nil)
    }

    @Test func autoInjectedSymbolFontMappingsFiltersCodepointsCoveredByConfiguredFont() throws {
        // Regression test: JetBrainsMono Nerd Font has U+25A0/U+25CB/U+25CF in
        // its own cmap but is missing U+25B0/U+25B1 (verified via CoreText on
        // a real install). Only the missing codepoints should be injected —
        // a whole-block override would clobber glyphs the font already has.
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = JetBrainsMono Nerd Font",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        let covered: Set<UInt32> = [0x25A0, 0x25CB, 0x25CF]
        let mappings = try #require(discovery.autoInjectedSymbolFontMappings(
            configPaths: [path],
            codepointCoverageProbe: { fontFamily, codepoint in
                #expect(fontFamily == "JetBrainsMono Nerd Font")
                return covered.contains(codepoint)
            }
        ))
        #expect(Set(mappings.map(\.0)) == ["U+25B0", "U+25B1", "U+2B21", "U+2B22"])
    }

    @Test func autoInjectedSymbolFontMappingsNilWhenAllCodepointsCovered() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = JetBrainsMono Nerd Font",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.autoInjectedSymbolFontMappings(
            configPaths: [path],
            codepointCoverageProbe: { _, _ in true }
        ) == nil)
    }

    @Test func fontContainsGlyphHandlesSupplementaryPlaneCodepoints() throws {
        // U+1F600 GRINNING FACE requires a UTF-16 surrogate pair; this is a
        // regression test for fontContainsGlyph incorrectly reporting "not
        // covered" for any codepoint above U+FFFF (which would make
        // autoInjectedSymbolFontMappings force an override even when the
        // font already has the glyph, for any future non-BMP addition to
        // symbolCodepoints).
        //
        // "Apple Color Emoji" is a system font rather than a repo-controlled
        // fixture, but it ships with every supported macOS. CTFontCreateWithName
        // substitutes silently when a name does not resolve, so require the
        // exact family rather than skipping: a substituted font would make the
        // coverage assertions below meaningless, and skipping would hide that.
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 12, nil)
        try #require(
            CTFontCopyFamilyName(font) as String == "Apple Color Emoji",
            "Apple Color Emoji did not resolve; CoreText substituted another font"
        )
        #expect(GhosttyConfigDiscovery.fontContainsGlyph(font, forCodepoint: 0x1F600))
        #expect(!GhosttyConfigDiscovery.fontContainsGlyph(font, forCodepoint: 0x10FFFE))
    }

    @Test func autoInjectedSymbolFontMappingsFailsClosedWhenFontCannotBeProbed() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = Some Unresolvable Font",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.autoInjectedSymbolFontMappings(configPaths: [path]) == nil)
    }

    @Test func shouldInjectSymbolFontFallbackMatchesMappingPresence() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = JetBrainsMono Nerd Font",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.shouldInjectSymbolFontFallback(
            configPaths: [path],
            codepointCoverageProbe: { _, _ in false }
        ))
        #expect(!discovery.shouldInjectSymbolFontFallback(
            configPaths: [path],
            codepointCoverageProbe: { _, _ in true }
        ))
    }

    @Test func autoInjectedSymbolFontMappingsSkipDefaultFaceCoverageWhenNoFontFamilyConfigured() throws {
        // Regression test: with no `font-family`, Ghostty's primary face is
        // its embedded JetBrains Mono, and a `font-codepoint-map` entry
        // outranks that face. Injecting the whole managed set here would push
        // ■/○/● onto Apple Symbols even though the default face renders them,
        // which is the same over-reach the per-codepoint filter avoids for
        // configured fonts.
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [path: "font-size = 13"])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        let mappings = try #require(discovery.autoInjectedSymbolFontMappings(configPaths: [path]))
        #expect(Set(mappings.map(\.0)) == ["U+25B0", "U+25B1", "U+2B21", "U+2B22"])
        #expect(mappings.allSatisfy { $0.1 == GhosttyConfigDiscovery.symbolFallbackFont })
    }

    @Test func defaultFaceCoveredSymbolCodepointsMatchGhosttysEmbeddedFont() throws {
        // `defaultFaceCoveredSymbolCodepoints` is a hard-coded table because
        // Ghostty's default face is embedded in its binary rather than
        // installed system-wide, so it can't be resolved by family name.
        // Probe the vendored copy of that font so the table fails here if the
        // ghostty submodule ever moves to a default face with different
        // coverage. The vendored static regular stands in for the variable
        // build the app actually loads; both are JetBrains Mono.
        //
        // This file lives at
        // Packages/macOS/CmuxTerminalCore/Tests/CmuxTerminalCoreTests/, so six
        // deletions reach the repo root (which contains ghostty/).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontURL = repoRoot.appendingPathComponent("ghostty/src/font/res/JetBrainsMonoNoNF-Regular.ttf")
        // A missing file means the ghostty submodule is not checked out; fail
        // loudly rather than let the drift check silently pass.
        let fontData = try #require(
            try? Data(contentsOf: fontURL),
            "ghostty submodule not initialized; run ./scripts/setup.sh"
        )
        let provider = try #require(CGDataProvider(data: fontData as CFData))
        let cgFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        #expect(CTFontCopyFamilyName(font) as String == "JetBrains Mono")

        let covered = Set(GhosttyConfigDiscovery.symbolCodepoints.filter {
            GhosttyConfigDiscovery.fontContainsGlyph(font, forCodepoint: $0)
        })
        #expect(covered == GhosttyConfigDiscovery.defaultFaceCoveredSymbolCodepoints)
    }
}

@Suite struct GhosttyConfigDiscoveryFontSummaryTests {
    @Test func detectsCodepointMapDirective() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [path: "font-codepoint-map = U+4E00-U+9FFF=Foo"])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.userConfigContainsCJKCodepointMap(configPaths: [path]))
    }

    @Test func emptyCodepointMapClearsFlag() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-codepoint-map = U+4E00=Foo\nfont-codepoint-map = ",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(!discovery.userConfigContainsCJKCodepointMap(configPaths: [path]))
    }

    @Test func multipleFontFamiliesAreExplicitFallbackChain() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = JetBrains Mono\nfont-family = Hiragino Sans",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path]))
    }

    @Test func emptyFontFamilyResetsChain() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "font-family = A\nfont-family = B\nfont-family = \nfont-family = C",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(!discovery.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path]))
    }

    @Test func commentsAndBlankLinesIgnored() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [
            path: "# comment\n\n  # font-codepoint-map = ignored\nfont-family = Mono",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        let summary = discovery.userFontConfigSummary(configPaths: [path])
        #expect(!summary.containsCodepointMap)
        #expect(summary.effectiveFontFamilies == ["Mono"])
    }

    @Test func followsConfigFileIncludeRelativeToParent() {
        let main = "/cfg/config"
        let included = "/cfg/extra.conf"
        let reader = FakeFileReader(contentsByPath: [
            main: "config-file = extra.conf",
            included: "font-codepoint-map = U+4E00=Foo",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.userConfigContainsCJKCodepointMap(configPaths: [main]))
    }
}

@Suite struct GhosttyConfigDiscoveryLegacyTests {
    private let discovery = GhosttyConfigDiscovery(fontProbe: NoFontProbe())

    @Test func loadLegacyOnlyWhenNewIsEmptyAndLegacyNonEmpty() {
        #expect(discovery.shouldLoadLegacyGhosttyConfig(newConfigFileSize: 0, legacyConfigFileSize: 10))
        #expect(!discovery.shouldLoadLegacyGhosttyConfig(newConfigFileSize: 5, legacyConfigFileSize: 10))
        #expect(!discovery.shouldLoadLegacyGhosttyConfig(newConfigFileSize: 0, legacyConfigFileSize: 0))
        #expect(!discovery.shouldLoadLegacyGhosttyConfig(newConfigFileSize: nil, legacyConfigFileSize: 10))
    }

    @Test func includeLegacyInScanPathsWhenNewMissingOrEmpty() {
        #expect(discovery.shouldIncludeLegacyGhosttyConfigInScanPaths(newConfigFileSize: nil, legacyConfigFileSize: 10))
        #expect(discovery.shouldIncludeLegacyGhosttyConfigInScanPaths(newConfigFileSize: 0, legacyConfigFileSize: 10))
        #expect(!discovery.shouldIncludeLegacyGhosttyConfigInScanPaths(newConfigFileSize: 5, legacyConfigFileSize: 10))
        #expect(!discovery.shouldIncludeLegacyGhosttyConfigInScanPaths(newConfigFileSize: 0, legacyConfigFileSize: 0))
    }
}

@Suite struct GhosttyConfigDiscoveryScanPathsTests {
    @Test func scanPathsIncludeNativeAndUserConfigLocations() throws {
        let appSupport = URL(fileURLWithPath: "/AppSupport", isDirectory: true)
        let reader = FakeFileReader()
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        let paths = discovery.loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: "com.cmuxterm.app",
            appSupportDirectory: appSupport
        )
        #expect(paths.contains("~/.config/ghostty/config"))
        #expect(paths.contains("~/.config/ghostty/config.ghostty"))
        #expect(paths.contains("/AppSupport/com.mitchellh.ghostty/config.ghostty"))
    }

    @Test func nativeLegacyIncludedWhenNewEmpty() {
        let appSupport = URL(fileURLWithPath: "/AppSupport", isDirectory: true)
        let reader = FakeFileReader(contentsByPath: [
            "/AppSupport/com.mitchellh.ghostty/config": "theme = foo",
            "/AppSupport/com.mitchellh.ghostty/config.ghostty": "",
        ])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        let paths = discovery.loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: "com.cmuxterm.app",
            appSupportDirectory: appSupport
        )
        #expect(paths.contains("/AppSupport/com.mitchellh.ghostty/config"))
    }
}

@Suite struct GhosttyConfigDiscoveryThemeOverrideTests {
    @Test func nonConditionalThemeNeedsNoOverride() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [path: "theme = Dracula"])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.conditionalThemeOverrideConfigContents(
            preferredColorScheme: .dark,
            configPaths: [path]
        ) == nil)
    }

    @Test func noThemeDirectiveYieldsNil() {
        let path = "/cfg/config"
        let reader = FakeFileReader(contentsByPath: [path: "font-family = Mono"])
        let discovery = GhosttyConfigDiscovery(fileReader: reader, fontProbe: NoFontProbe())
        #expect(discovery.conditionalThemeOverrideConfigContents(
            preferredColorScheme: .dark,
            configPaths: [path]
        ) == nil)
    }
}
