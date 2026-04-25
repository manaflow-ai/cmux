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

    private static let cmuxReleaseBundleIdentifier = "com.cmuxterm.app"
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
    var backgroundOpacity: Double = 1.0
    var foregroundColor: NSColor = NSColor(hex: "#fdfff1")!
    var cursorColor: NSColor = NSColor(hex: "#c0c1b5")!
    var cursorTextColor: NSColor = NSColor(hex: "#8d8e82")!
    var selectionBackground: NSColor = NSColor(hex: "#57584f")!
    var selectionForeground: NSColor = NSColor(hex: "#fdfff1")!

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

        func paths(for bundleIdentifier: String) -> [String] {
            let directory = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
            return [
                directory.appendingPathComponent("config", isDirectory: false).path,
                directory.appendingPathComponent("config.ghostty", isDirectory: false).path,
            ]
        }

        func hasConfig(_ paths: [String]) -> Bool {
            paths.contains { path in
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let type = attributes[.type] as? FileAttributeType,
                      type == .typeRegular,
                      let size = attributes[.size] as? NSNumber else {
                    return false
                }
                return size.intValue > 0
            }
        }

        let releasePaths = paths(for: cmuxReleaseBundleIdentifier)
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return releasePaths
        }
        if currentBundleIdentifier == cmuxReleaseBundleIdentifier {
            return releasePaths
        }

        let currentPaths = paths(for: currentBundleIdentifier)
        if hasConfig(currentPaths) {
            return currentPaths
        }
        if SocketControlSettings.isDebugLikeBundleIdentifier(currentBundleIdentifier) {
            return releasePaths
        }
        return []
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
        let configPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath } + cmuxConfigPaths()

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            for path in configPaths {
                if let contents = readConfigFile(at: path) {
                    config.parse(contents)
                }
            }

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
            config.parse(contents)
        }
        #else
        for path in configPaths {
            if let contents = readConfigFile(at: path) {
                config.parse(contents)
            }
        }

        if config.theme == nil,
           GhosttyApp.shouldApplyManagedDefaultAppearance(configPaths: configPaths) {
            config.applyCmuxDefaultAppearance(
                environment: ProcessInfo.processInfo.environment,
                bundleResourceURL: Bundle.main.resourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif

        // Load theme if specified
        if let themeName = config.theme {
            config.loadTheme(
                themeName,
                environment: ProcessInfo.processInfo.environment,
                bundleResourceURL: Bundle.main.resourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }

        config.resolveSidebarBackground(preferredColorScheme: preferredColorScheme)
        config.applySidebarAppearanceToUserDefaults()
        config.applyGlobalMagnificationIfNeeded()

        return config
    }

    /// Multiply the parsed terminal and tab-bar font sizes by the global
    /// magnification so both scale in lockstep with SwiftUI chrome.
    mutating func applyGlobalMagnificationIfNeeded() {
        guard !GlobalFontMagnification.isDefault else { return }
        let scale = GlobalFontMagnification.scale
        fontSize = max(1, fontSize * scale)
        surfaceTabBarFontSize = max(1, surfaceTabBarFontSize * scale)
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

    mutating func parse(_ contents: String) {
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
                case "working-directory":
                    workingDirectory = value
                case "scrollback-limit":
                    if let limit = Self.parseIntegerLiteral(value) {
                        scrollbackLimit = limit
                    }
                case "background":
                    if let color = NSColor(hex: value) {
                        backgroundColor = color
                    }
                case "background-opacity":
                    if let opacity = Double(value) {
                        backgroundOpacity = opacity
                    }
                case "foreground":
                    if let color = NSColor(hex: value) {
                        foregroundColor = color
                    }
                case "cursor-color":
                    if let color = NSColor(hex: value) {
                        cursorColor = color
                    }
                case "cursor-text":
                    if let color = NSColor(hex: value) {
                        cursorTextColor = color
                    }
                case "selection-background":
                    if let color = NSColor(hex: value) {
                        selectionBackground = color
                    }
                case "selection-foreground":
                    if let color = NSColor(hex: value) {
                        selectionForeground = color
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

    private static func parseIntegerLiteral(_ value: String) -> Int? {
        // Strip digit-group separators (for example 10_000_000).
        // Hex and float literals are intentionally unsupported here.
        let normalized = value.replacingOccurrences(of: "_", with: "")
        guard let parsed = Int(normalized), parsed >= 0 else {
            return nil
        }
        return parsed
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
        appAppearance: NSAppearance? = NSApp?.effectiveAppearance
    ) -> ColorSchemePreference {
        let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua ? .dark : .light
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

/// App-wide magnification for cmux's chrome and terminals.
///
/// Stored as an integer percent (100 = default, 150 = 1.5x, 200 = 2x, ...).
/// Every SwiftUI `.font(...)` call site is expected to go through the
/// `cmuxFont(size:)` / `cmuxFont(_:)` view modifiers, which multiply the
/// design-time size by `scale` and read via `@AppStorage` so they re-render
/// when the user changes the value in Settings.
///
/// Ghostty's terminal font size is scaled by the same factor (`fontSize`
/// in the parsed `GhosttyConfig` is multiplied on load, and the resulting
/// value is injected into Ghostty's live config). Per-pane runtime zoom
/// (cmd+=/-/0 while a terminal pane is focused, or the browser's own zoom)
/// still acts on top of whatever magnification resolved to.
enum GlobalFontMagnification {
    static let percentKey = "globalFontMagnificationPercent"

    static let defaultPercent: Int = 100
    static let minimumPercent: Int = 50
    /// Capped at 200% so cmux's fixed-size chrome (titlebar height, command
    /// palette rows, badge frames, browser panel button hit areas) doesn't
    /// clip or overflow. Users who need larger magnification should reach for
    /// macOS Accessibility → Zoom for system-wide scaling instead.
    static let maximumPercent: Int = 200
    static let stepPercent: Int = 10

    static let didChangeNotification = Notification.Name("cmux.globalFontMagnification.didChange")

    /// Raw percent stored in UserDefaults. If the key is unset, treat as 100%.
    /// Accepts any numeric storage (Int / Double NSNumber) and string-encoded
    /// integers so values written by `defaults write -float`/`-string` from a
    /// terminal still resolve cleanly instead of falling back to default.
    static var storedPercent: Int {
        let raw = UserDefaults.standard.object(forKey: percentKey)
        let resolved: Int
        if let number = raw as? NSNumber {
            resolved = number.intValue
        } else if let string = raw as? String, let parsed = Int(string) {
            resolved = parsed
        } else {
            resolved = defaultPercent
        }
        return clamp(resolved)
    }

    /// Multiplier (1.0 for 100%, 1.5 for 150%, ...). Always returns a finite
    /// positive number so multiplying hardcoded sizes is always safe.
    static var scale: CGFloat {
        CGFloat(storedPercent) / CGFloat(defaultPercent)
    }

    /// `true` when the user has left magnification at the default 100%.
    static var isDefault: Bool { storedPercent == defaultPercent }

    /// Scale a design-time point size by the current magnification. Clamped
    /// to at least 1pt to avoid zero-size fonts.
    static func scaled(_ base: CGFloat) -> CGFloat {
        max(1, base * scale)
    }

    static func clamp(_ percent: Int) -> Int {
        Swift.max(minimumPercent, Swift.min(maximumPercent, percent))
    }

    static func setPercent(_ percent: Int) {
        UserDefaults.standard.set(clamp(percent), forKey: percentKey)
        // AppDelegate's `installGlobalFontSizeObserver` owns cache + reload.
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Restores the default magnification. Writes `defaultPercent` explicitly
    /// (rather than `removeObject`) so storage stays symmetric with the UI
    /// reset path — both leave the key present at 100. Callers in the file
    /// store rely on stored-value equality to decide whether to fire change
    /// notifications, and the asymmetry would silently skip reloads after a
    /// UI-driven reset.
    static func resetToDefault() {
        UserDefaults.standard.set(defaultPercent, forKey: percentKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
