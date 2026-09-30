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
