import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference: Hashable {
        case light
        case dark
    }

    // Native fallback for fresh installs when the user hasn't chosen terminal colors yet.
    static let cmuxDefaultLightThemeName = "Apple System Colors Light"
    static let cmuxDefaultDarkThemeName = "Apple System Colors"

    private static let loadCacheLock = NSLock()
    private static var cachedConfigsByColorScheme: [ColorSchemePreference: GhosttyConfig] = [:]

    var fontFamily: String = "Menlo"
    var fontSize: CGFloat = 12
    var surfaceTabBarFontSize: CGFloat = 11
    var theme: String?
    var workingDirectory: String?
    // Ghostty measures scrollback-limit in bytes, not lines.
    var scrollbackLimit: Int = 10_000_000
    var unfocusedSplitOpacity: Double = 0.7
    var unfocusedSplitFill: NSColor?
    var splitDividerColor: NSColor?

    // Colors (from theme or config)
    var backgroundColor: NSColor = NSColor(hex: "#272822")!
    var hasBackgroundColorDirective = false
    var hasParsedBackgroundColor = false
    var backgroundOpacity: Double = 1.0
    var hasBackgroundOpacityDirective = false
    var hasParsedBackgroundOpacity = false
    var backgroundBlur: GhosttyBackgroundBlur = .disabled
    var hasBackgroundBlurDirective = false
    var hasParsedBackgroundBlur = false
    var foregroundColor: NSColor = NSColor(hex: "#fdfff1")!
    var hasForegroundColorDirective = false
    var hasParsedForegroundColor = false
    var cursorColor: NSColor = NSColor(hex: "#c0c1b5")!
    var hasCursorColorDirective = false
    var hasParsedCursorColor = false
    var cursorTextColor: NSColor = NSColor(hex: "#8d8e82")!
    var hasCursorTextColorDirective = false
    var hasParsedCursorTextColor = false
    var selectionBackground: NSColor = NSColor(hex: "#57584f")!
    var hasSelectionBackgroundDirective = false
    var hasParsedSelectionBackground = false
    var selectionForeground: NSColor = NSColor(hex: "#fdfff1")!
    var hasSelectionForegroundDirective = false
    var hasParsedSelectionForeground = false

    // Sidebar appearance
    var rawSidebarBackground: String?
    var sidebarBackground: NSColor?
    var sidebarBackgroundLight: NSColor?
    var sidebarBackgroundDark: NSColor?
    var sidebarTintOpacity: Double?

    // Palette colors (0-15)
    var palette: [Int: NSColor] = [:]

    var unfocusedSplitOverlayOpacity: Double {
        let clamped = min(1.0, max(0.15, unfocusedSplitOpacity))
        return min(1.0, max(0.0, 1.0 - clamped))
    }

    var unfocusedSplitOverlayFill: NSColor {
        unfocusedSplitFill ?? backgroundColor
    }

    var resolvedSplitDividerColor: NSColor {
        if let splitDividerColor {
            return splitDividerColor
        }

        let isLightBackground = backgroundColor.isLightColor
        return backgroundColor.darken(by: isLightBackground ? 0.08 : 0.4)
    }

    static func load(
        preferredColorScheme: ColorSchemePreference? = nil,
        useCache: Bool = true,
        loadFromDisk: (_ preferredColorScheme: ColorSchemePreference) -> GhosttyConfig = Self.loadFromDisk
    ) -> GhosttyConfig {
        let resolvedColorScheme = preferredColorScheme ?? currentColorSchemePreference()
        if useCache, let cached = cachedLoad(for: resolvedColorScheme) {
            return cached
        }

        let loaded = loadFromDisk(resolvedColorScheme)
        if useCache {
            storeCachedLoad(loaded, for: resolvedColorScheme)
        }
        return loaded
    }

    static func invalidateLoadCache() {
        loadCacheLock.lock()
        cachedConfigsByColorScheme.removeAll()
        loadCacheLock.unlock()
    }

    private static func cachedLoad(for colorScheme: ColorSchemePreference) -> GhosttyConfig? {
        loadCacheLock.lock()
        defer { loadCacheLock.unlock() }
        return cachedConfigsByColorScheme[colorScheme]
    }

    private static func storeCachedLoad(
        _ config: GhosttyConfig,
        for colorScheme: ColorSchemePreference
    ) {
        loadCacheLock.lock()
        cachedConfigsByColorScheme[colorScheme] = config
        loadCacheLock.unlock()
    }

    private static func cmuxConfigPaths(
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        return GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fileManager
        ).map(\.path)
    }

    mutating func resolveSidebarBackground(preferredColorScheme: ColorSchemePreference) {
        guard let raw = rawSidebarBackground else { return }

        let lightResolved = Self.resolveThemeName(from: raw, preferredColorScheme: .light)
        let darkResolved = Self.resolveThemeName(from: raw, preferredColorScheme: .dark)
        let hasDualMode = lightResolved != darkResolved

        if hasDualMode {
            sidebarBackgroundLight = NSColor(hex: lightResolved)
            sidebarBackgroundDark = NSColor(hex: darkResolved)
        }

        let resolved = Self.resolveThemeName(from: raw, preferredColorScheme: preferredColorScheme)
        if let color = NSColor(hex: resolved) {
            sidebarBackground = color
        }
    }

    func applySidebarAppearanceToUserDefaults() {
        guard rawSidebarBackground != nil else {
            if let opacity = sidebarTintOpacity {
                UserDefaults.standard.set(opacity, forKey: "sidebarTintOpacity")
            }
            return
        }

        let defaults = UserDefaults.standard

        if let light = sidebarBackgroundLight {
            defaults.set(light.hexString(), forKey: "sidebarTintHexLight")
        } else {
            defaults.removeObject(forKey: "sidebarTintHexLight")
        }
        if let dark = sidebarBackgroundDark {
            defaults.set(dark.hexString(), forKey: "sidebarTintHexDark")
        } else {
            defaults.removeObject(forKey: "sidebarTintHexDark")
        }
        if let color = sidebarBackground {
            defaults.set(color.hexString(), forKey: "sidebarTintHex")
        } else {
            defaults.removeObject(forKey: "sidebarTintHex")
        }
        if let opacity = sidebarTintOpacity {
            defaults.set(opacity, forKey: "sidebarTintOpacity")
        }
    }

    private static func loadFromDisk(preferredColorScheme: ColorSchemePreference) -> GhosttyConfig {
        var config = GhosttyConfig()

        // Match Ghostty's default load order on macOS.
        let appSupportGhosttyDirectory = NSString(
            string: "~/Library/Application Support/com.mitchellh.ghostty"
        ).expandingTildeInPath
        let appSupportConfigGhostty = (appSupportGhosttyDirectory as NSString)
            .appendingPathComponent("config.ghostty")
        let appSupportLegacyConfig = (appSupportGhosttyDirectory as NSString)
            .appendingPathComponent("config")
        var configPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath }
        // Panecho privacy mode: skip the standalone Ghostty app config under
        // ~/Library/Application Support/com.mitchellh.ghostty (another app's data
        // -> triggers the macOS "access data from other apps" prompt). The
        // ~/.config/ghostty/config paths above are still honored.
        if !PrivacyMode.isEnabled {
            configPaths.append(appSupportConfigGhostty)
            if shouldIncludeLegacyGhosttyConfigInResolvedLoad(
                newConfigFileSize: configFileSize(at: appSupportConfigGhostty),
                legacyConfigFileSize: configFileSize(at: appSupportLegacyConfig)
            ) {
                configPaths.append(appSupportLegacyConfig)
            }
        }
        configPaths.append(contentsOf: cmuxConfigPaths())

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            loadConfigFiles(
                configPaths,
                into: &config,
                preferredColorScheme: preferredColorScheme
            )

            if config.theme == nil,
               GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
                config.applyCmuxDefaultAppearance(
                    environment: ProcessInfo.processInfo.environment,
                    bundleResourceURL: Bundle.main.resourceURL,
                    preferredColorScheme: preferredColorScheme
                )
            }
        } else if let contents = startupPreviewProfile.previewConfigContents(
            preferredColorScheme: preferredColorScheme
        ) {
            config.parse(
                contents,
                loadingThemesImmediatelyFor: preferredColorScheme
            )
        }
        #else
        loadConfigFiles(
            configPaths,
            into: &config,
            preferredColorScheme: preferredColorScheme
        )

        if config.theme == nil,
           GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
            config.applyCmuxDefaultAppearance(
                environment: ProcessInfo.processInfo.environment,
                bundleResourceURL: Bundle.main.resourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif

        config.resolveSidebarBackground(preferredColorScheme: preferredColorScheme)
        config.applySidebarAppearanceToUserDefaults()

        return config
    }

    mutating func applyCmuxDefaultAppearance(
        environment: [String: String],
        bundleResourceURL: URL?,
        preferredColorScheme: ColorSchemePreference
    ) {
        parse(
            Self.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            )
        )
    }

    static func cmuxDefaultThemeName(preferredColorScheme: ColorSchemePreference) -> String {
        switch preferredColorScheme {
        case .light:
            return cmuxDefaultLightThemeName
        case .dark:
            return cmuxDefaultDarkThemeName
        }
    }

    static func cmuxDefaultThemeConfigContents(
        preferredColorScheme: ColorSchemePreference,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> String {
        if let url = cmuxDefaultThemeConfigURL(
            preferredColorScheme: preferredColorScheme,
            environment: environment,
            bundleResourceURL: bundleResourceURL
        ), let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }

        return cmuxDefaultFallbackConfigContents(preferredColorScheme: preferredColorScheme)
    }

    static func cmuxDefaultThemeConfigURL(
        preferredColorScheme: ColorSchemePreference,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        let themeName = cmuxDefaultThemeName(preferredColorScheme: preferredColorScheme)
        for candidateName in themeNameCandidates(from: themeName) {
            for path in themeSearchPaths(
                forThemeName: candidateName,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            ) where (try? String(contentsOfFile: path, encoding: .utf8)) != nil {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func cmuxDefaultFallbackConfigContents(
        preferredColorScheme: ColorSchemePreference
    ) -> String {
        switch preferredColorScheme {
        case .light:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#e5bc00
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#69c9f2
            palette = 15=#ffffff
            background = #feffff
            foreground = #000000
            cursor-color = #98989d
            cursor-text = #ffffff
            selection-background = #abd8ff
            selection-foreground = #000000
            """
        case .dark:
            return """
            palette = 0=#1a1a1a
            palette = 1=#cc372e
            palette = 2=#26a439
            palette = 3=#cdac08
            palette = 4=#0869cb
            palette = 5=#9647bf
            palette = 6=#479ec2
            palette = 7=#98989d
            palette = 8=#464646
            palette = 9=#ff453a
            palette = 10=#32d74b
            palette = 11=#ffd60a
            palette = 12=#0a84ff
            palette = 13=#bf5af2
            palette = 14=#76d6ff
            palette = 15=#ffffff
            background = #1e1e1e
            foreground = #ffffff
            cursor-color = #98989d
            cursor-text = #ffffff
            selection-background = #3f638b
            selection-foreground = #ffffff
            """
        }
    }

    mutating func parse(
        _ contents: String,
        loadingThemesImmediatelyFor preferredColorScheme: ColorSchemePreference? = nil
    ) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                switch key {
                case "font-family":
                    fontFamily = value
                case "font-size":
                    if let size = Double(value) {
                        fontSize = CGFloat(size)
                    }
                case "surface-tab-bar-font-size":
                    if let size = Double(value) {
                        surfaceTabBarFontSize = CGFloat(size)
                    }
                case "theme":
                    theme = value
                    if let preferredColorScheme {
                        loadTheme(
                            value,
                            environment: ProcessInfo.processInfo.environment,
                            bundleResourceURL: Bundle.main.resourceURL,
                            preferredColorScheme: preferredColorScheme
                        )
                    }
                case "working-directory":
                    workingDirectory = value
                case "scrollback-limit":
                    if let limit = Self.parseIntegerLiteral(value) {
                        scrollbackLimit = limit
                    }
                case "background":
                    hasBackgroundColorDirective = true
                    if let color = NSColor(hex: value) {
                        backgroundColor = color
                        hasParsedBackgroundColor = true
                    } else {
                        hasParsedBackgroundColor = false
                    }
                case "background-opacity":
                    hasBackgroundOpacityDirective = true
                    if let opacity = Double(value) {
                        backgroundOpacity = min(1.0, max(0.0, opacity))
                        hasParsedBackgroundOpacity = true
                    } else {
                        hasParsedBackgroundOpacity = false
                    }
                case "background-blur":
                    hasBackgroundBlurDirective = true
                    if let parsedBlur = Self.parseBackgroundBlur(value) {
                        backgroundBlur = parsedBlur
                        hasParsedBackgroundBlur = true
                    } else {
                        hasParsedBackgroundBlur = false
                    }
                case "foreground":
                    hasForegroundColorDirective = true
                    if let color = NSColor(hex: value) {
                        foregroundColor = color
                        hasParsedForegroundColor = true
                    } else {
                        hasParsedForegroundColor = false
                    }
                case "cursor-color":
                    hasCursorColorDirective = true
                    if let color = NSColor(hex: value) {
                        cursorColor = color
                        hasParsedCursorColor = true
                    } else {
                        hasParsedCursorColor = false
                    }
                case "cursor-text":
                    hasCursorTextColorDirective = true
                    if let color = NSColor(hex: value) {
                        cursorTextColor = color
                        hasParsedCursorTextColor = true
                    } else {
                        hasParsedCursorTextColor = false
                    }
                case "selection-background":
                    hasSelectionBackgroundDirective = true
                    if let color = NSColor(hex: value) {
                        selectionBackground = color
                        hasParsedSelectionBackground = true
                    } else {
                        hasParsedSelectionBackground = false
                    }
                case "selection-foreground":
                    hasSelectionForegroundDirective = true
                    if let color = NSColor(hex: value) {
                        selectionForeground = color
                        hasParsedSelectionForeground = true
                    } else {
                        hasParsedSelectionForeground = false
                    }
                case "palette":
                    // Parse palette entries like "0=#272822"
                    let paletteParts = value.split(separator: "=", maxSplits: 1)
                    if paletteParts.count == 2,
                       let index = Int(paletteParts[0]),
                       let color = NSColor(hex: String(paletteParts[1])) {
                        palette[index] = color
                    }
                case "unfocused-split-opacity":
                    if let opacity = Double(value) {
                        unfocusedSplitOpacity = opacity
                    }
                case "unfocused-split-fill":
                    if let color = NSColor(hex: value) {
                        unfocusedSplitFill = color
                    }
                case "split-divider-color":
                    if let color = NSColor(hex: value) {
                        splitDividerColor = color
                    }
                case "sidebar-background":
                    rawSidebarBackground = value
                case "sidebar-tint-opacity":
                    if let opacity = Double(value) {
                        sidebarTintOpacity = min(max(opacity, 0), 1)
                    }
                default:
                    break
                }
            }
        }
    }

    private static func loadConfigFiles(
        _ paths: [String],
        into config: inout GhosttyConfig,
        preferredColorScheme: ColorSchemePreference
    ) {
        var recursiveConfigPaths: [String] = []
        var loadedConfigPaths = Set<String>()

        for path in paths.map({ NSString(string: $0).expandingTildeInPath }) {
            loadConfigFile(
                at: path,
                into: &config,
                preferredColorScheme: preferredColorScheme,
                recursiveConfigPaths: &recursiveConfigPaths,
                loadedConfigPaths: &loadedConfigPaths,
                markLoadedPath: false
            )
        }

        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            loadConfigFile(
                at: path,
                into: &config,
                preferredColorScheme: preferredColorScheme,
                recursiveConfigPaths: &recursiveConfigPaths,
                loadedConfigPaths: &loadedConfigPaths,
                markLoadedPath: true
            )
        }
    }

    private static func loadConfigFile(
        at path: String,
        into config: inout GhosttyConfig,
        preferredColorScheme: ColorSchemePreference,
        recursiveConfigPaths: inout [String],
        loadedConfigPaths: inout Set<String>,
        markLoadedPath: Bool
    ) {
        let resolved = (path as NSString).standardizingPath
        if markLoadedPath {
            guard !loadedConfigPaths.contains(resolved) else { return }
        }
        guard let contents = readConfigFile(at: resolved) else { return }
        if markLoadedPath {
            loadedConfigPaths.insert(resolved)
        }

        config.parse(
            contents,
            loadingThemesImmediatelyFor: preferredColorScheme
        )

        let parentDir = (resolved as NSString).deletingLastPathComponent
        collectRecursiveConfigPaths(
            from: contents,
            parentDir: parentDir,
            recursiveConfigPaths: &recursiveConfigPaths
        )
    }

    private static func collectRecursiveConfigPaths(
        from contents: String,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line),
                  entry.key == "config-file" else {
                continue
            }
            guard let value = entry.value else { continue }
            applyConfigFileDirective(
                value,
                valueWasQuoted: entry.valueWasQuoted,
                parentDir: parentDir,
                recursiveConfigPaths: &recursiveConfigPaths
            )
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

    private static func parseIntegerLiteral(_ value: String) -> Int? {
        // Strip digit-group separators (for example 10_000_000).
        // Hex and float literals are intentionally unsupported here.
        let normalized = value.replacingOccurrences(of: "_", with: "")
        guard let parsed = Int(normalized), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    private static func parseBackgroundBlur(_ value: String) -> GhosttyBackgroundBlur? {
        switch value {
        case "false", "0":
            return .disabled
        case "true":
            return .radius(20)
        case "macos-glass-regular":
            return .macosGlassRegular
        case "macos-glass-clear":
            return .macosGlassClear
        default:
            guard let radius = parseIntegerLiteral(value), radius > 0, radius <= Int(UInt8.max) else {
                return nil
            }
            return .radius(radius)
        }
    }

    mutating func loadTheme(_ name: String) {
        loadTheme(
            name,
            environment: ProcessInfo.processInfo.environment,
            bundleResourceURL: Bundle.main.resourceURL
        )
    }

    mutating func loadTheme(
        _ name: String,
        environment: [String: String],
        bundleResourceURL: URL?,
        preferredColorScheme: ColorSchemePreference? = nil
    ) {
        let resolvedThemeName = Self.resolveThemeName(
            from: name,
            preferredColorScheme: preferredColorScheme ?? Self.currentColorSchemePreference()
        )
        let expandedThemePath = NSString(string: resolvedThemeName).expandingTildeInPath
        if (expandedThemePath as NSString).isAbsolutePath,
           let contents = try? String(contentsOfFile: expandedThemePath, encoding: .utf8) {
            parse(contents)
            return
        }

        for candidateName in Self.themeNameCandidates(from: resolvedThemeName) {
            for path in Self.themeSearchPaths(
                forThemeName: candidateName,
                environment: environment,
                bundleResourceURL: bundleResourceURL
            ) {
                if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                    parse(contents)
                    return
                }
            }
        }
    }

    static func currentColorSchemePreference(
        appAppearance _: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: AppearanceSettings.SystemAppearance? = nil
    ) -> ColorSchemePreference {
        return AppearanceSettings.terminalColorSchemePreference(defaults: defaults, systemAppearance: systemAppearance)
    }

    static func resolveThemeName(
        from rawThemeValue: String,
        preferredColorScheme: ColorSchemePreference
    ) -> String {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        switch preferredColorScheme {
        case .light:
            if let lightTheme {
                return lightTheme
            }
        case .dark:
            if let darkTheme {
                return darkTheme
            }
        }

        if let fallbackTheme {
            return fallbackTheme
        }
        if let darkTheme {
            return darkTheme
        }
        if let lightTheme {
            return lightTheme
        }
        return rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func themeValueUsesSameResolvedThemeInBothColorSchemes(_ rawThemeValue: String) -> Bool {
        let lightTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .light)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .dark)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty, !darkTheme.isEmpty else { return false }
        return lightTheme.caseInsensitiveCompare(darkTheme) == .orderedSame
    }

    static func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    static func themeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliasGroups: [[String]] = [
            ["Solarized Light", "iTerm2 Solarized Light"],
            ["Solarized Dark", "iTerm2 Solarized Dark"],
        ]

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }

            for group in compatibilityAliasGroups {
                if group.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    for alias in group where alias.caseInsensitiveCompare(trimmed) != .orderedSame {
                        if !candidates.contains(alias) {
                            candidates.append(alias)
                        }
                    }
                }
            }
        }

        var queue: [String] = [rawName]
        while let current = queue.popLast() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            appendCandidate(trimmed)

            let lower = trimmed.lowercased()
            if lower.hasPrefix("builtin ") {
                let stripped = String(trimmed.dropFirst("builtin ".count))
                appendCandidate(stripped)
                queue.append(stripped)
            }

            if let range = trimmed.range(
                of: #"\s*\(builtin\)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let stripped = String(trimmed[..<range.lowerBound])
                appendCandidate(stripped)
                queue.append(stripped)
            }
        }

        return candidates
    }

    static func themeSearchPaths(
        forThemeName themeName: String,
        environment: [String: String],
        bundleResourceURL: URL?
    ) -> [String] {
        var paths: [String] = []

        func appendUniquePath(_ path: String?) {
            guard let path else { return }
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            if !paths.contains(expanded) {
                paths.append(expanded)
            }
        }

        func appendThemePath(in resourcesRoot: String?) {
            guard let resourcesRoot else { return }
            let expanded = NSString(string: resourcesRoot).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            appendUniquePath(
                URL(fileURLWithPath: expanded)
                    .appendingPathComponent("themes/\(themeName)")
                    .path
            )
        }

        // 1) Explicit resources dir used by the running Ghostty embedding.
        appendThemePath(in: environment["GHOSTTY_RESOURCES_DIR"])

        // 2) App bundle resources.
        appendUniquePath(
            bundleResourceURL?
                .appendingPathComponent("ghostty/themes/\(themeName)")
                .path
        )

        // 3) Data dirs (Ghostty installs themes under share/ghostty/themes).
        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init) {
                guard !dataDir.isEmpty else { continue }
                appendUniquePath(
                    URL(fileURLWithPath: dataDir)
                        .appendingPathComponent("ghostty/themes/\(themeName)")
                        .path
                )
            }
        }

        // 4) Common system/user fallback locations.
        appendUniquePath("/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(themeName)")
        appendUniquePath("~/.config/ghostty/themes/\(themeName)")
        for appSupportDirectory in CmuxApplicationSupportDirectories.userDirectories(environment: environment) {
            appendUniquePath(
                appSupportDirectory
                    .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent(themeName, isDirectory: false)
                    .path
            )
        }
        // Panecho privacy mode: do not probe the standalone Ghostty app theme dir.
        if !PrivacyMode.isEnabled {
            appendUniquePath("~/Library/Application Support/com.mitchellh.ghostty/themes/\(themeName)")
        }

        return paths
    }

    private static func readConfigFile(at path: String) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }

        if let attributes = try? fileManager.attributesOfItem(atPath: path) {
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeSymbolicLink {
                return nil
            }
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                return nil
            }
        }

        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func configFileSize(at path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func shouldIncludeLegacyGhosttyConfigInResolvedLoad(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b: CGFloat
        if hexSanitized.count == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    var isLightColor: Bool {
        luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }
}
