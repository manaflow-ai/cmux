import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference: Hashable {
        case light
        case dark
    }

    private struct ThemeSettingComponents {
        var fallback: String?
        var light: String?
        var dark: String?
        var hasExplicitVariants = false
    }

    private static let loadCacheLock = NSLock()
    private static var cachedConfigsByColorScheme: [ColorSchemePreference: GhosttyConfig] = [:]

    var fontFamily: String = "Menlo"
    var fontSize: CGFloat = 12
    var theme: String?
    var workingDirectory: String?
    var scrollbackLimit: Int = 10000
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

    private static func loadFromDisk(preferredColorScheme: ColorSchemePreference) -> GhosttyConfig {
        var config = GhosttyConfig()

        // Match Ghostty's default load order on macOS.
        let configPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath }

        for path in configPaths {
            if let contents = readConfigFile(at: path) {
                config.parse(contents)
            }
        }

        // Load theme if specified
        if let themeName = config.theme {
            config.loadTheme(
                themeName,
                environment: ProcessInfo.processInfo.environment,
                bundleResourceURL: Bundle.main.resourceURL,
                preferredColorScheme: preferredColorScheme
            )
        }

        return config
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
                case "theme":
                    theme = value
                case "working-directory":
                    workingDirectory = value
                case "scrollback-limit":
                    if let limit = Int(value) {
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
                default:
                    break
                }
            }
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
        let components = themeSettingComponents(from: rawThemeValue)

        switch preferredColorScheme {
        case .light:
            if let lightTheme = components.light {
                return lightTheme
            }
        case .dark:
            if let darkTheme = components.dark {
                return darkTheme
            }
        }

        if let fallbackTheme = components.fallback {
            return fallbackTheme
        }
        if let darkTheme = components.dark {
            return darkTheme
        }
        if let lightTheme = components.light {
            return lightTheme
        }
        return rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func themeNameCandidates(from rawName: String) -> [String] {
        var candidates: [String] = []
        let compatibilityAliases: [String: [String]] = [
            "solarized light": ["iTerm2 Solarized Light"],
            "solarized dark": ["iTerm2 Solarized Dark"],
        ]

        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }

            if let aliases = compatibilityAliases[trimmed.lowercased()] {
                for alias in aliases {
                    if !candidates.contains(alias) {
                        candidates.append(alias)
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

    static func themeSearchDirectories(
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

        func appendThemeDirectory(in resourcesRoot: String?) {
            guard let resourcesRoot else { return }
            let expanded = NSString(string: resourcesRoot).expandingTildeInPath
            guard !expanded.isEmpty else { return }
            appendUniquePath(
                URL(fileURLWithPath: expanded)
                    .appendingPathComponent("themes", isDirectory: true)
                    .path
            )
        }

        appendThemeDirectory(in: environment["GHOSTTY_RESOURCES_DIR"])
        appendUniquePath(
            bundleResourceURL?
                .appendingPathComponent("ghostty/themes", isDirectory: true)
                .path
        )

        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init) {
                guard !dataDir.isEmpty else { continue }
                appendUniquePath(
                    URL(fileURLWithPath: dataDir)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                        .path
                )
            }
        }

        appendUniquePath("/Applications/Ghostty.app/Contents/Resources/ghostty/themes")
        appendUniquePath("~/.config/ghostty/themes")
        appendUniquePath("~/Library/Application Support/com.mitchellh.ghostty/themes")

        return paths
    }

    static func discoverThemeNames(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> [String] {
        var discovered: [String] = []
        var seen: Set<String> = []

        for directory in themeSearchDirectories(
            environment: environment,
            bundleResourceURL: bundleResourceURL
        ) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                guard values?.isRegularFile == true else { continue }
                let name = child.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let normalized = name
                    .folding(options: [.caseInsensitive], locale: .current)
                    .lowercased()
                guard seen.insert(normalized).inserted else { continue }
                discovered.append(name)
            }
        }

        return discovered.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func configSearchPaths() -> [String] {
        [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath }
    }

    static func writableConfigPath(
        fileManager: FileManager = .default,
        searchPaths: [String]? = nil
    ) -> String {
        let resolvedSearchPaths = searchPaths ?? configSearchPaths()
        for path in resolvedSearchPaths.reversed() where fileManager.fileExists(atPath: path) {
            return path
        }
        return resolvedSearchPaths.last ?? NSString(string: "~/.config/ghostty/config.ghostty").expandingTildeInPath
    }

    @discardableResult
    static func upsertConfigValue(
        key: String,
        value: String,
        fileManager: FileManager = .default,
        searchPaths: [String]? = nil
    ) throws -> String {
        let path = writableConfigPath(fileManager: fileManager, searchPaths: searchPaths)
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing: String
        if fileManager.fileExists(atPath: path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }
        var lines = configLines(from: existing)

        var replaced = false
        var lastMatchIndex: Int?
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard let rawKey = parts.first?.trimmingCharacters(in: .whitespaces),
                  rawKey == key else {
                continue
            }
            lastMatchIndex = index
        }

        if let index = lastMatchIndex {
            let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
            lines[index] = "\(indentation)\(key) = \(value)"
            replaced = true
        }

        if !replaced {
            if !lines.isEmpty, !(lines.last?.isEmpty ?? true) {
                lines.append("")
            }
            lines.append("\(key) = \(value)")
        }

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    static func applyTheme(
        _ themeName: String,
        fileManager: FileManager = .default,
        preferredColorScheme: ColorSchemePreference = currentColorSchemePreference(),
        searchPaths: [String]? = nil
    ) throws -> String {
        guard !themeName.contains(where: { $0.isNewline || $0 == "," }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let path = writableConfigPath(fileManager: fileManager, searchPaths: searchPaths)
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing: String
        if fileManager.fileExists(atPath: path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }
        var lines = configLines(from: existing)
        let lastThemeAssignment = lastActiveConfigAssignment(forKey: "theme", in: lines)
        let nextThemeValue = updatedThemeValueForSelection(
            existingThemeValue: lastThemeAssignment?.value,
            selectedTheme: themeName,
            preferredColorScheme: preferredColorScheme
        )

        if let assignment = lastThemeAssignment {
            let indentation = String(lines[assignment.index].prefix { $0 == " " || $0 == "\t" })
            lines[assignment.index] = "\(indentation)theme = \(nextThemeValue)"
        } else {
            if !lines.isEmpty, !(lines.last?.isEmpty ?? true) {
                lines.append("")
            }
            lines.append("theme = \(nextThemeValue)")
        }

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return path
    }

    static func updatedThemeValueForSelection(
        existingThemeValue: String?,
        selectedTheme: String,
        preferredColorScheme: ColorSchemePreference
    ) -> String {
        guard let existingThemeValue else { return selectedTheme }
        let components = themeSettingComponents(from: existingThemeValue)
        guard components.hasExplicitVariants else { return selectedTheme }

        var updated = components
        switch preferredColorScheme {
        case .light:
            updated.light = selectedTheme
        case .dark:
            updated.dark = selectedTheme
        }

        var entries: [String] = []
        if let fallback = updated.fallback, !fallback.isEmpty {
            entries.append(fallback)
        }
        if let light = updated.light, !light.isEmpty {
            entries.append("light:\(light)")
        }
        if let dark = updated.dark, !dark.isEmpty {
            entries.append("dark:\(dark)")
        }
        return entries.isEmpty ? selectedTheme : entries.joined(separator: ",")
    }

    private static func themeSettingComponents(from rawThemeValue: String) -> ThemeSettingComponents {
        var components = ThemeSettingComponents()

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if components.fallback == nil {
                    components.fallback = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                components.hasExplicitVariants = true
                if components.light == nil {
                    components.light = value
                }
            case "dark":
                components.hasExplicitVariants = true
                if components.dark == nil {
                    components.dark = value
                }
            default:
                if components.fallback == nil {
                    components.fallback = value
                }
            }
        }

        return components
    }

    private static func configLines(from contents: String) -> [String] {
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func lastActiveConfigAssignment(
        forKey key: String,
        in lines: [String]
    ) -> (index: Int, value: String)? {
        for index in lines.indices.reversed() {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard let rawKey = parts.first?.trimmingCharacters(in: .whitespaces),
                  rawKey == key else {
                continue
            }

            let rawValue = parts.count == 2
                ? parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                : ""
            return (index, rawValue)
        }
        return nil
    }

    private static func readConfigFile(at path: String) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }

        if let attributes = try? fileManager.attributesOfItem(atPath: path) {
            if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
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
