public import Foundation
public import CoreText
public import CmuxFoundation

/// Resolves where cmux's Ghostty configuration lives and what it should inject,
/// without touching the live `ghostty_config_t`. It discovers the ordered
/// top-level config scan paths, scans those files (following `config-file`
/// includes) for the font and appearance directives that drive cmux's
/// managed-default-theme and CJK-fallback decisions, decides whether to load the
/// legacy `config` file, and computes the conditional-theme override text.
///
/// All work is pure with respect to the injected ``GhosttyConfigFileReading``
/// and ``GhosttyFontProbing`` seams, so the C-API config-load methods that stay
/// in the app target call these to decide *what* to load, then perform the
/// actual `ghostty_config_load_*` calls themselves. The type is a value with
/// injected collaborators (no globals), constructed at the composition root.
public struct GhosttyConfigDiscovery {
    /// The release bundle identifier whose Application Support config directory
    /// is always included in the scan paths, regardless of the running build's
    /// own identifier.
    public static let releaseBundleIdentifier = CmuxGhosttyConfigPathResolver.releaseBundleIdentifier

    private let fileReader: any GhosttyConfigFileReading
    private let fontProbe: any GhosttyFontProbing
    private let pathResolver: CmuxGhosttyConfigPathResolver

    /// Creates a discovery value with the given filesystem and font seams.
    ///
    /// Defaults reproduce the app's prior behavior exactly: a
    /// `FileManager.default`-backed reader and a CoreText-backed font probe.
    public init(
        fileReader: any GhosttyConfigFileReading = FileManagerGhosttyConfigFileReader(),
        fontProbe: any GhosttyFontProbing = CoreTextGhosttyFontProbe(),
        pathResolver: CmuxGhosttyConfigPathResolver = CmuxGhosttyConfigPathResolver()
    ) {
        self.fileReader = fileReader
        self.fontProbe = fontProbe
        self.pathResolver = pathResolver
    }

    // MARK: - CJK font fallback ranges

    /// Unicode ranges shared by all CJK languages (Han ideographs, symbols,
    /// fullwidth forms).
    public static let sharedCJKRanges = [
        "U+3000-U+303F",  // CJK Symbols and Punctuation
        "U+4E00-U+9FFF",  // CJK Unified Ideographs
        "U+F900-U+FAFF",  // CJK Compatibility Ideographs
        "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
        "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    ]

    /// Unicode ranges specific to Japanese (kana).
    public static let japaneseRanges = [
        "U+3040-U+309F",  // Hiragana
        "U+30A0-U+30FF",  // Katakana
    ]

    /// Representative scalars used to detect whether the configured primary font
    /// already covers the ranges cmux would otherwise auto-map.
    public static let cjkCoverageSampleCharactersByRange: [String: [UniChar]] = [
        "U+3000-U+303F": [0x3001, 0x300C],
        "U+4E00-U+9FFF": [0x4E00, 0x65E5, 0x6C34],
        "U+F900-U+FAFF": [0xF900],
        "U+FF00-U+FFEF": [0xFF10, 0xFF21],
        "U+3400-U+4DBF": [0x3400],
        "U+1100-U+11FF": [0x1100, 0x1161],
        "U+3130-U+318F": [0x3131, 0x314F],
        "U+3040-U+309F": [0x3042, 0x3093],
        "U+30A0-U+30FF": [0x30A2, 0x30F3],
        "U+AC00-U+D7AF": [0xAC00, 0xD55C],
    ]

    // MARK: - CJK font mappings

    /// Returns `(range, font)` pairs for CJK font fallback based on the system's
    /// preferred languages, or `nil` if no CJK language is detected. Each
    /// language only maps its own script ranges to avoid assigning glyphs to a
    /// font that lacks coverage (e.g. Hangul to Hiragino Sans).
    public func cjkFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [(String, String)]? {
        var mappings: [(String, String)] = []
        var coveredShared = false

        for lang in preferredLanguages {
            let lower = lang.lowercased()
            let font: String
            var langRanges: [String] = []

            if lower.hasPrefix("ja") {
                font = "Hiragino Sans"
                langRanges = Self.japaneseRanges
            } else if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                font = "PingFang TC"
            } else if lower.hasPrefix("zh") {
                font = "PingFang SC"
            } else {
                continue
            }

            if !coveredShared {
                for range in Self.sharedCJKRanges {
                    mappings.append((range, font))
                }
                coveredShared = true
            }

            for range in langRanges {
                mappings.append((range, font))
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Returns only the CJK mappings cmux should auto-inject after respecting
    /// explicit user overrides and the glyph coverage of the configured primary
    /// font family.
    public func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String]? = nil,
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
        let configPaths = configPaths ?? loadedCJKScanPaths()
        guard var mappings = cjkFontMappings(preferredLanguages: preferredLanguages) else { return nil }

        let summary = userFontConfigSummary(configPaths: configPaths)
        if summary.containsCodepointMap || summary.hasExplicitFontFamilyFallbackChain {
            return nil
        }

        guard let configuredFontFamily = summary.effectiveFontFamilies.first else {
            return mappings
        }

        if let rangeCoverageProbe {
            mappings.removeAll { range, _ in
                rangeCoverageProbe(configuredFontFamily, range)
            }
        } else if let configuredFont = fontProbe.configuredFont(named: configuredFontFamily, size: 12) {
            mappings.removeAll { range, _ in
                Self.fontContainsGlyphs(configuredFont, forRange: range)
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Whether the user's Ghostty config files already contain a
    /// `font-codepoint-map` entry covering CJK ranges, following
    /// application-support config paths cmux may load at runtime.
    public func userConfigContainsCJKCodepointMap(
        configPaths: [String]? = nil
    ) -> Bool {
        let configPaths = configPaths ?? loadedGhosttyConfigScanPaths()
        return userFontConfigSummary(configPaths: configPaths).containsCodepointMap
    }

    /// Whether the user provided an explicit multi-entry `font-family` fallback
    /// chain across the resolved config paths.
    public func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String]? = nil
    ) -> Bool {
        let configPaths = configPaths ?? loadedGhosttyConfigScanPaths()
        return userFontConfigSummary(configPaths: configPaths).hasExplicitFontFamilyFallbackChain
    }

    /// Whether cmux should inject its managed CJK `font-codepoint-map` fallback.
    public func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String]? = nil,
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        let configPaths = configPaths ?? loadedCJKScanPaths()
        return autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        ) != nil
    }

    /// Whether cmux should apply its managed default appearance across the
    /// resolved config paths (delegates to ``GhosttyConfig``).
    public func shouldApplyManagedDefaultAppearance(
        configPaths: [String]? = nil
    ) -> Bool {
        let configPaths = configPaths ?? loadedGhosttyConfigScanPaths()
        return GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: configPaths)
    }

    /// Computes the resolved plain-theme override cmux must inject when the
    /// user's last `theme` directive uses Ghostty's conditional
    /// `light:…`/`dark:…` syntax, returning `nil` when no override is needed.
    public func conditionalThemeOverrideConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        configPaths: [String]? = nil
    ) -> String? {
        let configPaths = configPaths ?? loadedGhosttyConfigScanPaths()
        let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: configPaths)
        guard let rawThemeValue = summary.lastThemeDirective else { return nil }

        // Inject a resolved plain theme whenever the requested appearance side is
        // explicitly named via ghostty's conditional `light:...`/`dark:...`
        // syntax, even when both sides resolve to the same theme. `cmux themes
        // set` always encodes the selection with this syntax (a single theme
        // becomes `light:X,dark:X`), and ghostty mis-applies the conditional form
        // — the background lands but the foreground/palette stay at the default
        // white colors, producing the white-on-light terminals reported in
        // https://github.com/manaflow-ai/cmux/issues/3459. Only override sides the
        // value explicitly specifies: a one-sided `light:X` must not force the
        // light theme onto dark appearances (which would clobber the inherited or
        // default dark theme). Plain (non-conditional) theme values are applied
        // correctly by ghostty, so they need no override.
        guard let explicitTheme = GhosttyConfig.explicitConditionalThemeName(
            from: rawThemeValue,
            preferredColorScheme: preferredColorScheme
        ) else {
            return nil
        }

        let resolvedTheme = explicitTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTheme.isEmpty,
              resolvedTheme.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        return "theme = \(resolvedTheme)"
    }

    // MARK: - Font resolution

    /// Resolves auto-injected CJK families through the regular-weight descriptor
    /// path first so locale-sensitive families such as Hiragino Sans don't fall
    /// back to ultra-light faces like W0 when Ghostty later matches by name.
    public func resolvedInjectedCJKFontName(
        named name: String,
        size: CGFloat = 12
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        guard let regularWeightFont = fontProbe.discoveredFont(named: trimmed, size: size, weightTrait: 0.0) else {
            return trimmed
        }

        let candidateNames = [
            CTFontCopyName(regularWeightFont, kCTFontFullNameKey) as String?,
            CTFontCopyName(regularWeightFont, kCTFontPostScriptNameKey) as String?,
        ].compactMap { $0 }
        let expectedFullName = CTFontCopyFullName(regularWeightFont) as String
        let expectedPostScriptName = CTFontCopyPostScriptName(regularWeightFont) as String

        for candidate in candidateNames {
            guard let verifiedFont = fontProbe.discoveredFont(named: candidate, size: size, weightTrait: nil) else { continue }
            let verifiedNames = [
                CTFontCopyName(verifiedFont, kCTFontFamilyNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontFullNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontPostScriptNameKey) as String?,
            ].compactMap { $0 }
            let matchesRegularWeightFace = verifiedNames.contains {
                Self.normalizedFontName($0) == Self.normalizedFontName(expectedFullName) ||
                Self.normalizedFontName($0) == Self.normalizedFontName(expectedPostScriptName)
            }
            if matchesRegularWeightFace {
                return candidate
            }
        }

        return trimmed
    }

    /// Resolves a font by family name through the injected probe, mirroring
    /// Ghostty's CoreText family-name discovery path.
    public func discoveredFont(
        named name: String,
        size: CGFloat = 12,
        weightTrait: CGFloat? = nil
    ) -> CTFont? {
        fontProbe.discoveredFont(named: name, size: size, weightTrait: weightTrait)
    }

    static func fontContainsGlyphs(
        _ font: CTFont,
        forRange range: String
    ) -> Bool {
        guard let characters = cjkCoverageSampleCharactersByRange[range] else {
            return false
        }

        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let hasGlyphs = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return hasGlyphs && !glyphs.contains(0)
    }

    static func normalizedFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    // MARK: - Config file scanning

    /// Scans the resolved config files (following `config-file` includes) and
    /// summarizes the font directives relevant to cmux's injected CJK fallback.
    public func userFontConfigSummary(
        configPaths: [String]? = nil
    ) -> UserFontConfigSummary {
        let configPaths = configPaths ?? loadedCJKScanPaths()
        var summary = UserFontConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    private func scanFontConfigFile(
        atPath path: String,
        summary: inout UserFontConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = fileReader.contents(atPath: resolved) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = Self.parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "font-codepoint-map":
                guard let value = entry.value else { continue }
                summary.applyFontCodepointMap(value)
            case "font-family":
                guard let value = entry.value else { continue }
                summary.recordFontFamily(value)
            case "config-file":
                guard let value = entry.value else { continue }
                Self.applyConfigFileDirective(
                    value,
                    valueWasQuoted: entry.valueWasQuoted,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    static func parsedConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?, valueWasQuoted: Bool)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWasQuoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")

        if valueWasQuoted {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value), valueWasQuoted)
    }

    static func applyConfigFileDirective(
        _ value: String,
        valueWasQuoted: Bool,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        if value.isEmpty {
            recursiveConfigPaths.removeAll()
            return
        }

        var includePath = value
        if !valueWasQuoted, includePath.hasPrefix("?") {
            includePath.removeFirst()
            if includePath.count >= 2,
               includePath.hasPrefix("\""),
               includePath.hasSuffix("\"") {
                includePath.removeFirst()
                includePath.removeLast()
            }
        }
        guard !includePath.isEmpty else { return }

        let expanded = NSString(string: includePath).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (parentDir as NSString).appendingPathComponent(expanded)
        recursiveConfigPaths.append(absolute)
    }

    // MARK: - Scan paths and legacy config

    /// Returns the top-level Ghostty config paths cmux may load before recursive
    /// `config-file` processing, including native Ghostty, legacy, and cmux
    /// Application Support locations.
    public func loadedGhosttyConfigScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        var paths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ]

        guard let appSupportDirectory else { return paths }

        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        paths.append(nativeConfig.path)
        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: fileReader.fileSize(atPath: nativeConfig.path),
            legacyConfigFileSize: fileReader.fileSize(atPath: nativeLegacyConfig.path)
        ) {
            paths.append(nativeLegacyConfig.path)
        }

        guard let bundleId = currentBundleIdentifier,
              !bundleId.isEmpty else { return paths }

        let appSupportConfigURLs = cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleId,
            appSupportDirectory: appSupportDirectory
        )
        paths.append(contentsOf: appSupportConfigURLs.map(\.path))

        let releaseDir = appSupportDirectory.appendingPathComponent(Self.releaseBundleIdentifier, isDirectory: true)
        let releaseLegacyConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        let releaseConfig = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)

        let releaseConfigSize = fileReader.fileSize(atPath: releaseConfig.path)
        let releaseLegacyConfigSize = fileReader.fileSize(atPath: releaseLegacyConfig.path)

        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: releaseConfigSize,
            legacyConfigFileSize: releaseLegacyConfigSize
        ), !paths.contains(releaseLegacyConfig.path) {
            paths.append(releaseLegacyConfig.path)
        }

        return paths
    }

    /// The config paths scanned for CJK font directives (identical to
    /// ``loadedGhosttyConfigScanPaths(currentBundleIdentifier:appSupportDirectory:)``).
    public func loadedCJKScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    /// Whether cmux should load the legacy `config` file because the new
    /// `config.ghostty` is empty (size 0). Only true when the legacy file is
    /// non-empty and the new file is exactly empty.
    ///
    /// Pure with respect to its inputs; an instance method (not a static
    /// namespace member) so call sites invoke it on the held discovery value
    /// rather than as `GhosttyConfigDiscovery.shouldLoadLegacyGhosttyConfig(...)`.
    public func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return newConfigFileSize == 0
    }

    /// Whether the legacy `config` path should be included in the scan paths:
    /// true when the legacy file is non-empty and the new file is absent or
    /// empty.
    ///
    /// Pure with respect to its inputs; an instance method (not a static
    /// namespace member) so call sites invoke it on the held discovery value.
    public func shouldIncludeLegacyGhosttyConfigInScanPaths(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }

    /// Whether the native Ghostty legacy baseline should be ignored when
    /// resolving unparsed appearance: true only when both the native legacy and
    /// native new config files are present and non-empty.
    public func shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> Bool {
        guard let appSupportDirectory else { return false }
        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        guard let legacyConfigSize = fileReader.fileSize(atPath: nativeLegacyConfig.path), legacyConfigSize > 0 else {
            return false
        }
        guard let nativeConfigSize = fileReader.fileSize(atPath: nativeConfig.path), nativeConfigSize > 0 else {
            return false
        }
        return true
    }

    /// Resolves the cmux Application Support Ghostty config file URLs for the
    /// running build, via the shared ``CmuxGhosttyConfigPathResolver``.
    public func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        pathResolver.loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }
}
