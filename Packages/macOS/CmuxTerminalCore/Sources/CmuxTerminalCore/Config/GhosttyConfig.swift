public import AppKit
public import CmuxFoundation
public import Foundation

/// The resolved cmux terminal configuration: fonts, colors, theme, scrollback,
/// and sidebar appearance parsed from the user's ghostty config files plus
/// cmux's managed defaults.
///
/// `GhosttyConfig` is the value type that drives the embedded ghostty runtime's
/// appearance. It parses ghostty's textual config format (``parse(_:loadingThemesImmediatelyFor:)``),
/// resolves themes by light/dark color scheme, and folds in cmux's managed
/// default appearance — as a base underneath the user's explicit color
/// directives — whenever the user has not set a `theme`. The wire format it
/// reads (directive keys, theme resolution, NSColor hex codecs) is frozen and
/// pinned by tests.
public struct GhosttyConfig {
    /// The light/dark terminal theme preference. An alias for
    /// ``TerminalColorSchemePreference``; the nested name keeps the
    /// `GhosttyConfig.ColorSchemePreference` call-site spelling stable across the
    /// terminal view/engine code.
    public typealias ColorSchemePreference = TerminalColorSchemePreference

    /// Native fallback light theme name used for fresh installs before the user
    /// has chosen terminal colors.
    public static let cmuxDefaultLightThemeName = "Apple System Colors Light"
    /// Native fallback dark theme name used for fresh installs before the user
    /// has chosen terminal colors.
    public static let cmuxDefaultDarkThemeName = "Apple System Colors"

    private static let loadCacheLock = NSLock()
    // Every read/write of this cache is serialized by `loadCacheLock`; the
    // nonisolated static mirrors the app-target lock-guarded cache contract.
    nonisolated(unsafe) private static var cachedConfigsByColorScheme: [String: GhosttyConfig] = [:]
    /// The default sidebar font size, in points.
    public static let defaultSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.defaultSidebarFontSize)
    /// The minimum sidebar font size the parser will clamp to.
    public static let minSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.minSidebarFontSize)
    /// The maximum sidebar font size the parser will clamp to.
    public static let maxSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.maxSidebarFontSize)
    /// The default surface tab-bar font size, in points.
    public static let defaultSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize)
    /// The minimum surface tab-bar font size the parser will clamp to.
    public static let minSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.minSurfaceTabBarFontSize)
    /// The maximum surface tab-bar font size the parser will clamp to.
    public static let maxSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.maxSurfaceTabBarFontSize)

    /// The terminal font family.
    public var fontFamily: String = "Menlo"
    /// The terminal font size, in points.
    public var fontSize: CGFloat = 12
    /// The surface tab-bar font size, in points.
    public var surfaceTabBarFontSize: CGFloat = Self.defaultSurfaceTabBarFontSize
    /// The sidebar font size, in points.
    public var sidebarFontSize: CGFloat = Self.defaultSidebarFontSize
    /// The configured `theme` directive value, or `nil` when unset.
    public var theme: String?
    /// The configured `working-directory`, or `nil` when unset.
    public var workingDirectory: String?
    /// The scrollback limit. Ghostty measures this in bytes, not lines.
    public var scrollbackLimit: Int = 10_000_000
    /// The opacity (0...1) applied to unfocused split panes.
    public var unfocusedSplitOpacity: Double = 0.7
    /// The fill color for the unfocused-split overlay, or `nil` to use the
    /// background color.
    public var unfocusedSplitFill: NSColor?
    /// The explicit split-divider color, or `nil` to derive one from the
    /// background.
    public var splitDividerColor: NSColor?

    // Colors (from theme or config)
    /// The terminal background color.
    public var backgroundColor: NSColor = NSColor(hex: "#272822")!
    /// Whether a `background` directive was seen, regardless of whether it parsed.
    public var hasBackgroundColorDirective = false
    /// Whether the `background` directive parsed to a valid color.
    public var hasParsedBackgroundColor = false
    /// The terminal background opacity (0...1).
    public var backgroundOpacity: Double = 1.0
    /// Whether a `background-opacity` directive was seen.
    public var hasBackgroundOpacityDirective = false
    /// Whether the `background-opacity` directive parsed to a valid value.
    public var hasParsedBackgroundOpacity = false
    /// The background blur configuration.
    public var backgroundBlur: GhosttyBackgroundBlur = .disabled
    /// Whether a `background-blur` directive was seen.
    public var hasBackgroundBlurDirective = false
    /// Whether the `background-blur` directive parsed to a valid value.
    public var hasParsedBackgroundBlur = false
    /// The terminal foreground color.
    public var foregroundColor: NSColor = NSColor(hex: "#fdfff1")!
    /// Whether a `foreground` directive was seen.
    public var hasForegroundColorDirective = false
    /// Whether the `foreground` directive parsed to a valid color.
    public var hasParsedForegroundColor = false
    /// The cursor color.
    public var cursorColor: NSColor = NSColor(hex: "#c0c1b5")!
    /// Whether a `cursor-color` directive was seen.
    public var hasCursorColorDirective = false
    /// Whether the `cursor-color` directive parsed to a valid color.
    public var hasParsedCursorColor = false
    /// The cursor text color.
    public var cursorTextColor: NSColor = NSColor(hex: "#8d8e82")!
    /// Whether a `cursor-text` directive was seen.
    public var hasCursorTextColorDirective = false
    /// Whether the `cursor-text` directive parsed to a valid color.
    public var hasParsedCursorTextColor = false
    /// The selection background color.
    public var selectionBackground: NSColor = NSColor(hex: "#57584f")!
    /// Whether a `selection-background` directive was seen.
    public var hasSelectionBackgroundDirective = false
    /// Whether the `selection-background` directive parsed to a valid color.
    public var hasParsedSelectionBackground = false
    /// The selection foreground color.
    public var selectionForeground: NSColor = NSColor(hex: "#fdfff1")!
    /// Whether a `selection-foreground` directive was seen.
    public var hasSelectionForegroundDirective = false
    /// Whether the `selection-foreground` directive parsed to a valid color.
    public var hasParsedSelectionForeground = false

    // Sidebar appearance
    /// The raw `sidebar-background` directive value before theme resolution.
    public var rawSidebarBackground: String?
    /// The resolved sidebar background color for the active color scheme.
    public var sidebarBackground: NSColor?
    /// The resolved sidebar background color for light mode (dual-mode themes).
    public var sidebarBackgroundLight: NSColor?
    /// The resolved sidebar background color for dark mode (dual-mode themes).
    public var sidebarBackgroundDark: NSColor?
    /// The sidebar tint opacity (0...1), or `nil` when unset.
    public var sidebarTintOpacity: Double?

    /// The 16-color ANSI palette, indexed 0...15.
    public var palette: [Int: NSColor] = [:]

    /// Creates a config with cmux's built-in default appearance, before any
    /// config file or theme is parsed.
    public init() {}

    /// The opacity (0...1) of the overlay drawn over unfocused splits, derived
    /// from ``unfocusedSplitOpacity``.
    public var unfocusedSplitOverlayOpacity: Double {
        let clamped = min(1.0, max(0.15, unfocusedSplitOpacity))
        return min(1.0, max(0.0, 1.0 - clamped))
    }

    /// The fill color of the unfocused-split overlay: the explicit
    /// ``unfocusedSplitFill`` when set, otherwise the background color.
    public var unfocusedSplitOverlayFill: NSColor {
        unfocusedSplitFill ?? backgroundColor
    }

    /// The split-divider color: the explicit ``splitDividerColor`` when set,
    /// otherwise a contrast-adjusted shade of the background color.
    public var resolvedSplitDividerColor: NSColor {
        if let splitDividerColor {
            return splitDividerColor
        }

        let isLightBackground = backgroundColor.isLightColor
        return backgroundColor.darken(by: isLightBackground ? 0.08 : 0.4)
    }

    /// Loads the resolved terminal config for `preferredColorScheme` (or the
    /// current system/app preference when `nil`), caching per color scheme plus
    /// optional app-injected magnification percent. `loadFromDisk` is injectable
    /// for tests; pass `nil` for deterministic base config values.
    public static func load(
        preferredColorScheme: ColorSchemePreference? = nil,
        useCache: Bool = true,
        globalFontMagnificationPercent: Int? = nil,
        loadFromDisk: (_ preferredColorScheme: ColorSchemePreference) -> GhosttyConfig = Self.loadFromDisk
    ) -> GhosttyConfig {
        let resolvedColorScheme = preferredColorScheme ?? currentColorSchemePreference()
        let magnificationPercent = globalFontMagnificationPercent.map(GlobalFontMagnification.clamp)
        let cacheKey = "\(resolvedColorScheme)#\(magnificationPercent ?? -1)"
        if useCache {
            let cached: GhosttyConfig? = {
                loadCacheLock.lock()
                defer { loadCacheLock.unlock() }
                return cachedConfigsByColorScheme[cacheKey]
            }()
            if let cached {
                return cached
            }
        }

        var loaded = loadFromDisk(resolvedColorScheme)
        if let magnificationPercent { loaded.applyGlobalMagnification(percent: magnificationPercent) }
        if useCache {
            loadCacheLock.lock()
            cachedConfigsByColorScheme[cacheKey] = loaded
            loadCacheLock.unlock()
        }
        return loaded
    }

    /// Drops every cached config so the next ``load(preferredColorScheme:useCache:globalFontMagnificationPercent:loadFromDisk:)`` re-reads from disk.
    public static func invalidateLoadCache() {
        loadCacheLock.lock()
        cachedConfigsByColorScheme.removeAll()
        loadCacheLock.unlock()
    }

    private static func cmuxConfigPaths(
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        return CmuxGhosttyConfigPathResolver().loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fileManager
        ).map(\.path)
    }

    /// Resolves the sidebar background color(s) from the raw `sidebar-background`
    /// directive for `preferredColorScheme`, populating the light/dark variants
    /// when the theme differs between modes.
    public mutating func resolveSidebarBackground(preferredColorScheme: ColorSchemePreference) {
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

    /// Writes the resolved sidebar appearance (tint colors and opacity) into
    /// `UserDefaults.standard` so the SwiftUI sidebar can read them.
    public func applySidebarAppearanceToUserDefaults() {
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

    // Internal + @usableFromInline so it can back the public `load` default
    // argument value (default args of public APIs are emitted into callers and
    // cannot reference a `private` symbol). The body is not inlinable; this only
    // widens the symbol's reference visibility, not its definition.
    @usableFromInline
    static func loadFromDisk(preferredColorScheme: ColorSchemePreference) -> GhosttyConfig {
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
        configPaths.append(appSupportConfigGhostty)
        if shouldIncludeLegacyGhosttyConfigInResolvedLoad(
            newConfigFileSize: configFileSize(at: appSupportConfigGhostty),
            legacyConfigFileSize: configFileSize(at: appSupportLegacyConfig)
        ) {
            configPaths.append(appSupportLegacyConfig)
        }
        configPaths.append(contentsOf: cmuxConfigPaths())

        #if DEBUG
        let startupPreviewOverride = TerminalStartupAppearancePreviewOverride.installed
        if startupPreviewOverride?.loadsRealUserConfig ?? true {
            config.loadResolvedUserConfig(
                configPaths: configPaths,
                preferredColorScheme: preferredColorScheme
            )
        } else if let contents = startupPreviewOverride?.previewConfigContents(
            preferredColorScheme
        ) {
            config.parse(
                contents,
                loadingThemesImmediatelyFor: preferredColorScheme
            )
        }
        #else
        config.loadResolvedUserConfig(
            configPaths: configPaths,
            preferredColorScheme: preferredColorScheme
        )
        #endif

        config.resolveSidebarBackground(preferredColorScheme: preferredColorScheme)
        config.applySidebarAppearanceToUserDefaults()

        return config
    }

    /// Applies cmux's managed default appearance (when the user has not chosen
    /// a `theme`) as the base, then parses the user's config files on top so
    /// explicit color directives override just those colors — matching
    /// ghostty's own theme semantics
    /// (https://github.com/manaflow-ai/cmux/issues/7161).
    mutating func loadResolvedUserConfig(
        configPaths: [String],
        preferredColorScheme: ColorSchemePreference,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) {
        if Self.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
            applyCmuxDefaultAppearance(
                environment: environment,
                bundleResourceURL: bundleResourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }
        Self.loadConfigFiles(
            configPaths,
            into: &self,
            preferredColorScheme: preferredColorScheme
        )
    }

    mutating func applyGlobalMagnification(percent: Int) {
        let scale = GlobalFontMagnification.scale(for: percent)
        guard scale != 1 else { return }
        fontSize = max(1, fontSize * scale)
        surfaceTabBarFontSize = max(1, surfaceTabBarFontSize * scale)
    }

    /// Applies cmux's managed default theme for `preferredColorScheme` by parsing
    /// the bundled (or fallback) theme config contents into this config. Apply it
    /// before parsing the user's config files so their explicit color directives
    /// override individual managed colors.
    public mutating func applyCmuxDefaultAppearance(
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

    /// The cmux managed default theme name for `preferredColorScheme`.
    public static func cmuxDefaultThemeName(preferredColorScheme: ColorSchemePreference) -> String {
        switch preferredColorScheme {
        case .light:
            return cmuxDefaultLightThemeName
        case .dark:
            return cmuxDefaultDarkThemeName
        }
    }

    /// The cmux managed default theme's config contents for `preferredColorScheme`,
    /// read from the resolved theme file when available, otherwise a built-in
    /// fallback palette.
    public static func cmuxDefaultThemeConfigContents(
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

    /// The on-disk URL of the cmux managed default theme for `preferredColorScheme`,
    /// or `nil` when no candidate theme file exists.
    public static func cmuxDefaultThemeConfigURL(
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

    /// Parses ghostty-format config `contents` into this config. When
    /// `preferredColorScheme` is provided, `theme` directives load their resolved
    /// theme immediately.
    public mutating func parse(
        _ contents: String,
        loadingThemesImmediatelyFor preferredColorScheme: ColorSchemePreference? = nil
    ) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // Strip a leading UTF-8 BOM so a BOM-encoded first line (e.g. a
            // `sidebar-font-size` setting) is still parsed instead of silently
            // ignored, matching `CmuxGhosttyConfigSettingEditor.parsedSetting`.
            if trimmed.hasPrefix("\u{FEFF}") {
                trimmed.removeFirst()
                trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            }
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
                    if let size = Double(value), size.isFinite {
                        surfaceTabBarFontSize = Self.clampedSurfaceTabBarFontSize(CGFloat(size))
                    }
                case "sidebar-font-size":
                    if let size = Double(value), size.isFinite {
                        sidebarFontSize = Self.clampedSidebarFontSize(CGFloat(size))
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

    /// A scan of the user's resolved Ghostty config for the appearance
    /// directives that determine whether cmux should apply its managed default
    /// theme, and the last `theme` value seen.
    public struct UserAppearanceConfigSummary {
        /// Whether any `theme` directive was seen.
        public var hasThemeDirective = false
        /// The last non-empty `theme` directive value seen, or `nil`.
        public var lastThemeDirective: String?

        /// Creates an empty summary.
        public init() {}

        /// Whether cmux should apply its managed default appearance: true unless
        /// the user chose a `theme`. Explicit color directives (background,
        /// foreground, palette, cursor, selection) do not suppress the managed
        /// theme — they are loaded after it, overriding just those colors
        /// (https://github.com/manaflow-ai/cmux/issues/7161).
        public var shouldApplyDefaultAppearance: Bool {
            !hasThemeDirective
        }

        /// Records one config directive into the summary.
        public mutating func recordDirective(key: String, value: String?) {
            switch key {
            case "theme":
                hasThemeDirective = true
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lastThemeDirective = trimmedValue.isEmpty ? nil : trimmedValue
            default:
                break
            }
        }
    }

    /// Whether cmux should inject its managed default appearance: true unless
    /// the user has set an explicit `theme` across the resolved config paths.
    public static func shouldApplyManagedDefaultAppearance(
        configPaths: [String]
    ) -> Bool {
        userAppearanceConfigSummary(configPaths: configPaths).shouldApplyDefaultAppearance
    }

    /// Scans the given top-level config paths (following `config-file` includes)
    /// for the appearance directives that drive managed-default-theme decisions.
    public static func userAppearanceConfigSummary(
        configPaths: [String]
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
            case "theme":
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

    private static func parseIntegerLiteral(_ value: String) -> Int? {
        // Strip digit-group separators (for example 10_000_000).
        // Hex and float literals are intentionally unsupported here.
        let normalized = value.replacingOccurrences(of: "_", with: "")
        guard let parsed = Int(normalized), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    /// Clamps a sidebar font size into the supported range.
    public static func clampedSidebarFontSize(_ value: CGFloat) -> CGFloat {
        CGFloat(CmuxGhosttyConfigSettingEditor().clampedSidebarFontSize(Double(value)))
    }

    /// Clamps a surface tab-bar font size into the supported range.
    public static func clampedSurfaceTabBarFontSize(_ value: CGFloat) -> CGFloat {
        CGFloat(CmuxGhosttyConfigSettingEditor().clampedSurfaceTabBarFontSize(Double(value)))
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

    /// Loads the named theme into this config using the process environment and
    /// the main bundle's resources.
    public mutating func loadTheme(_ name: String) {
        loadTheme(
            name,
            environment: ProcessInfo.processInfo.environment,
            bundleResourceURL: Bundle.main.resourceURL
        )
    }

    /// Loads the named theme into this config, resolving paired
    /// `light:.../dark:...` themes for `preferredColorScheme` and searching the
    /// given `environment`/`bundleResourceURL` theme directories.
    public mutating func loadTheme(
        _ name: String,
        environment: [String: String],
        bundleResourceURL: URL?,
        preferredColorScheme: ColorSchemePreference? = nil
    ) {
        guard let resolvedThemeName = Self.appliedThemeName(
            from: name,
            preferredColorScheme: preferredColorScheme ?? Self.currentColorSchemePreference()
        ) else { return }
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

    /// The current light/dark terminal color-scheme preference, resolved from
    /// the given defaults and optional system appearance.
    public static func currentColorSchemePreference(
        appAppearance _: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: TerminalSystemAppearance? = nil
    ) -> ColorSchemePreference {
        return TerminalColorSchemePreference.current(
            defaults: defaults,
            systemAppearance: systemAppearance
        )
    }

    /// Resolves a raw `theme` directive value (which may carry conditional
    /// `light:.../dark:...` tokens) to the concrete theme name for
    /// `preferredColorScheme`, falling back across sides when one is unspecified.
    public static func resolveThemeName(
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

    /// Returns the theme name that the raw `theme` value *explicitly* assigns to
    /// `preferredColorScheme` via ghostty's conditional `light:...`/`dark:...`
    /// syntax, or `nil` when that side is not conditionally specified.
    ///
    /// Unlike ``resolveThemeName(from:preferredColorScheme:)``, this performs no
    /// cross-side fallback: `light:X` (with no `dark:` token) returns `X` for
    /// `.light` and `nil` for `.dark`. cmux injects a resolved plain `theme = X`
    /// override only for explicitly specified sides, because ghostty mis-applies
    /// the conditional form (the background lands but the foreground/palette stay
    /// at the default colors — see
    /// https://github.com/manaflow-ai/cmux/issues/3459). Injecting for an unset
    /// side would clobber the user's inherited/default theme for that appearance.
    public static func explicitConditionalThemeName(
        from rawThemeValue: String,
        preferredColorScheme: ColorSchemePreference
    ) -> String? {
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil { lightTheme = value }
            case "dark":
                if darkTheme == nil { darkTheme = value }
            default:
                continue
            }
        }

        switch preferredColorScheme {
        case .light:
            return lightTheme
        case .dark:
            return darkTheme
        }
    }

    /// Whether the raw `theme` value resolves to the same theme name in both
    /// light and dark color schemes (case-insensitively).
    public static func themeValueUsesSameResolvedThemeInBothColorSchemes(_ rawThemeValue: String) -> Bool {
        let lightTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .light)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = resolveThemeName(from: rawThemeValue, preferredColorScheme: .dark)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty, !darkTheme.isEmpty else { return false }
        return lightTheme.caseInsensitiveCompare(darkTheme) == .orderedSame
    }

    /// The last non-empty `theme` directive value in the given config contents,
    /// or `nil` when none is present.
    public static func lastThemeDirective(in contents: String) -> String? {
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

    /// Expands a raw theme name into the ordered list of candidate names to try
    /// on disk, including `builtin ...` prefix stripping and known compatibility
    /// aliases (e.g. iTerm2 Solarized variants).
    public static func themeNameCandidates(from rawName: String) -> [String] {
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

    /// The ordered list of filesystem paths cmux searches for the given theme
    /// name, spanning the ghostty resources dir, app bundle, XDG data dirs, and
    /// common system/user fallback locations.
    public static func themeSearchPaths(
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
        for appSupportDirectory in CmuxApplicationSupportDirectories(environment: environment).userDirectories {
            appendUniquePath(
                appSupportDirectory
                    .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent(themeName, isDirectory: false)
                    .path
            )
        }
        appendUniquePath("~/Library/Application Support/com.mitchellh.ghostty/themes/\(themeName)")

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
