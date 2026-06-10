import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - User config scanning, font/appearance summaries, CJK fallback
extension GhosttyApp {
    /// When the user has not configured `font-codepoint-map` for CJK ranges
    /// and has not already provided an explicit multi-entry `font-family`
    /// fallback chain, Ghostty's `CTFontCollection` scoring may pick an
    /// inappropriate fallback font for Hiragana, Katakana, and CJK symbols.
    /// The scoring prioritizes monospace fonts, so decorative fonts with
    /// monospace attributes (e.g. AB_appare from Adobe CC, or LingWai) can be
    /// selected depending on what is installed. This injects a sensible
    /// default based on the system's preferred languages without overriding
    /// user-managed fallback chains or configured fonts that already cover
    /// the affected CJK ranges.
    ///
    /// See: https://github.com/manaflow-ai/cmux/pull/1017
    func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        guard let mappings = Self.autoInjectedCJKFontMappings() else { return }

        var resolvedFonts: [String: String] = [:]
        let lines = mappings.map { range, font in
            let resolvedFont = resolvedFonts[font] ?? {
                let resolved = Self.resolvedInjectedCJKFontName(named: font)
                resolvedFonts[font] = resolved
                return resolved
            }()
            return "font-codepoint-map = \(range)=\(resolvedFont)"
        }.joined(separator: "\n")
        loadInlineGhosttyConfig(
            lines,
            into: config,
            prefix: "cmux-cjk-font-fallback",
            logLabel: "CJK font fallback"
        )
    }

    /// Unicode ranges shared by all CJK languages (Han ideographs, symbols, fullwidth forms).
    private static let sharedCJKRanges = [
        "U+3000-U+303F",  // CJK Symbols and Punctuation
        "U+4E00-U+9FFF",  // CJK Unified Ideographs
        "U+F900-U+FAFF",  // CJK Compatibility Ideographs
        "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
        "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    ]

    /// Unicode ranges specific to Japanese (kana).
    private static let japaneseRanges = [
        "U+3040-U+309F",  // Hiragana
        "U+30A0-U+30FF",  // Katakana
    ]

    /// Representative scalars used to detect whether the configured primary
    /// font already covers the ranges cmux would otherwise auto-map.
    private static let cjkCoverageSampleCharactersByRange: [String: [UniChar]] = [
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

    private struct UserFontConfigSummary {
        var containsCodepointMap = false
        var effectiveFontFamilies: [String] = []

        var hasExplicitFontFamilyFallbackChain: Bool {
            effectiveFontFamilies.count > 1
        }

        mutating func applyFontCodepointMap(_ value: String) {
            if value.isEmpty {
                containsCodepointMap = false
                return
            }

            guard value.contains("=") else {
                return
            }

            containsCodepointMap = true
        }

        mutating func recordFontFamily(_ value: String) {
            if value.isEmpty {
                effectiveFontFamilies.removeAll()
                return
            }

            guard !effectiveFontFamilies.contains(value) else {
                return
            }

            effectiveFontFamilies.append(value)
        }
    }

    private struct UserAppearanceConfigSummary {
        var hasThemeDirective = false
        var hasExplicitTerminalColorDirective = false
        var lastThemeDirective: String?

        var shouldApplyDefaultAppearance: Bool {
            !hasThemeDirective && !hasExplicitTerminalColorDirective
        }

        mutating func recordDirective(key: String, value: String?) {
            switch key {
            case "theme":
                hasThemeDirective = true
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lastThemeDirective = trimmedValue.isEmpty ? nil : trimmedValue
            case "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                hasExplicitTerminalColorDirective = true
            default:
                break
            }
        }
    }

    /// Returns (range, font) pairs for CJK font fallback based on the system's
    /// preferred languages, or nil if no CJK language is detected. Each language
    /// only maps its own script ranges to avoid assigning glyphs to a font that
    /// lacks coverage (e.g. Hangul to Hiragino Sans).
    static func cjkFontMappings(
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
                langRanges = japaneseRanges
            } else if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                font = "PingFang TC"
            } else if lower.hasPrefix("zh") {
                font = "PingFang SC"
            } else {
                continue
            }

            if !coveredShared {
                for range in sharedCJKRanges {
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
    /// explicit user overrides and the glyph coverage of the configured
    /// primary font family.
    static func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
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
        } else if let configuredFont = configuredCTFont(named: configuredFontFamily) {
            mappings.removeAll { range, _ in
                fontContainsGlyphs(configuredFont, forRange: range)
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Checks whether the user's Ghostty config files already contain
    /// a `font-codepoint-map` entry covering CJK ranges. Also checks
    /// application-support config paths that cmux may load at runtime.
    static func userConfigContainsCJKCodepointMap(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).containsCodepointMap
    }

    static func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).hasExplicitFontFamilyFallbackChain
    }

    static func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        ) != nil
    }

    static func shouldApplyManagedDefaultAppearance(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userAppearanceConfigSummary(configPaths: configPaths).shouldApplyDefaultAppearance
    }

    static func conditionalThemeOverrideConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> String? {
        let summary = userAppearanceConfigSummary(configPaths: configPaths)
        guard let rawThemeValue = summary.lastThemeDirective else { return nil }

        let lightTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .light
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .dark
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty,
              !darkTheme.isEmpty,
              lightTheme.caseInsensitiveCompare(darkTheme) != .orderedSame else {
            return nil
        }

        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: preferredColorScheme
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTheme.isEmpty,
              resolvedTheme.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        return "theme = \(resolvedTheme)"
    }

    /// Resolve auto-injected CJK families through the regular-weight descriptor
    /// path first so locale-sensitive families such as Hiragino Sans don't fall
    /// back to ultra-light faces like W0 when Ghostty later matches by name.
    static func resolvedInjectedCJKFontName(
        named name: String,
        size: CGFloat = 12
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        guard let regularWeightFont = discoveredCTFont(named: trimmed, size: size, weightTrait: 0.0) else {
            return trimmed
        }

        let candidateNames = [
            CTFontCopyName(regularWeightFont, kCTFontFullNameKey) as String?,
            CTFontCopyName(regularWeightFont, kCTFontPostScriptNameKey) as String?,
        ].compactMap { $0 }
        let expectedFullName = CTFontCopyFullName(regularWeightFont) as String
        let expectedPostScriptName = CTFontCopyPostScriptName(regularWeightFont) as String

        for candidate in candidateNames {
            guard let verifiedFont = discoveredCTFont(named: candidate, size: size) else { continue }
            let verifiedNames = [
                CTFontCopyName(verifiedFont, kCTFontFamilyNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontFullNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontPostScriptNameKey) as String?,
            ].compactMap { $0 }
            let matchesRegularWeightFace = verifiedNames.contains {
                normalizedFontName($0) == normalizedFontName(expectedFullName) ||
                normalizedFontName($0) == normalizedFontName(expectedPostScriptName)
            }
            if matchesRegularWeightFace {
                return candidate
            }
        }

        return trimmed
    }

    private static func configuredCTFont(
        named name: String,
        size: CGFloat = 12
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateWithName(trimmed as CFString, size, nil)
        let normalizedRequestedName = normalizedFontName(trimmed)
        let resolvedNames = [
            kCTFontFamilyNameKey,
            kCTFontFullNameKey,
            kCTFontPostScriptNameKey,
        ].compactMap { CTFontCopyName(font, $0) as String? }

        guard resolvedNames.contains(where: { normalizedFontName($0) == normalizedRequestedName }) else {
            return nil
        }

        return font
    }

    /// Mirror Ghostty's family-name CoreText discovery path so injected
    /// `font-codepoint-map` values are validated against the same lookup mode.
    static func discoveredCTFont(
        named name: String,
        size: CGFloat = 12,
        weightTrait: CGFloat? = nil
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: trimmed,
            kCTFontSizeAttribute: size,
        ]
        if let weightTrait {
            attributes[kCTFontTraitsAttribute] = [
                kCTFontWeightTrait: weightTrait,
            ] as CFDictionary
        }

        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let match = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor])?.first else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(match, size, nil)
    }

    private static func fontContainsGlyphs(
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

    private static func normalizedFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func userFontConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserFontConfigSummary {
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

    private static func userAppearanceConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserAppearanceConfigSummary {
        var summary = UserAppearanceConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanAppearanceConfigFile(
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

            scanAppearanceConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    /// Returns the top-level Ghostty config paths cmux may load before
    /// recursive `config-file` processing.
    static func loadedGhosttyConfigScanPaths(
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
            newConfigFileSize: configFileSize(at: nativeConfig),
            legacyConfigFileSize: configFileSize(at: nativeLegacyConfig)
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

        let releaseDir = appSupportDirectory.appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
        let releaseLegacyConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        let releaseConfig = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)

        let releaseConfigSize = configFileSize(at: releaseConfig)
        let releaseLegacyConfigSize = configFileSize(at: releaseLegacyConfig)

        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: releaseConfigSize,
            legacyConfigFileSize: releaseLegacyConfigSize
        ), !paths.contains(releaseLegacyConfig.path) {
            paths.append(releaseLegacyConfig.path)
        }

        return paths
    }

    static func loadedCJKScanPaths(
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

    private static func configFileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Scans a single config file for font settings relevant to cmux's
    /// injected CJK fallback and updates the pending recursive config-file
    /// queue using Ghostty's repeatable path semantics.
    private static func scanFontConfigFile(
        atPath path: String,
        summary: inout UserFontConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "font-codepoint-map":
                guard let value = entry.value else { continue }
                summary.applyFontCodepointMap(value)
            case "font-family":
                guard let value = entry.value else { continue }
                summary.recordFontFamily(value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
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

    private static func scanAppearanceConfigFile(
        atPath path: String,
        summary: inout UserAppearanceConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "theme",
                 "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                summary.recordDirective(key: entry.key, value: entry.value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
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

    private static func parsedConfigEntry(
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

    private static func applyConfigFileDirective(
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

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return newConfigFileSize == 0
    }

    static func shouldIncludeLegacyGhosttyConfigInScanPaths(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }

    static func shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> Bool {
        guard let appSupportDirectory else { return false }
        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        guard let legacyConfigSize = configFileSize(at: nativeLegacyConfig), legacyConfigSize > 0 else {
            return false
        }
        guard let nativeConfigSize = configFileSize(at: nativeConfig), nativeConfigSize > 0 else {
            return false
        }
        return true
    }

    static func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        CmuxGhosttyConfigPathResolver.loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }

    static func shouldApplyDefaultBackgroundUpdate(
        currentScope: GhosttyDefaultBackgroundUpdateScope,
        incomingScope: GhosttyDefaultBackgroundUpdateScope
    ) -> Bool {
        incomingScope.rawValue >= currentScope.rawValue
    }

    static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> Bool {
        previousColorScheme != currentColorScheme
    }

}
