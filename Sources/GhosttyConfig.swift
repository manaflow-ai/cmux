import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference {
        case light
        case dark
    }

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

    static func load() -> GhosttyConfig {
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
            config.loadTheme(themeName)
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
