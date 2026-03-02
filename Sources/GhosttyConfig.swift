import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference: Hashable {
        case light
        case dark
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
                    if let color = Self.parseColor(value) {
                        backgroundColor = color
                    }
                case "background-opacity":
                    if let opacity = Double(value) {
                        backgroundOpacity = opacity
                    }
                case "foreground":
                    if let color = Self.parseColor(value) {
                        foregroundColor = color
                    }
                case "cursor-color":
                    if let color = Self.parseColor(value) {
                        cursorColor = color
                    }
                case "cursor-text":
                    if let color = Self.parseColor(value) {
                        cursorTextColor = color
                    }
                case "selection-background":
                    if let color = Self.parseColor(value) {
                        selectionBackground = color
                    }
                case "selection-foreground":
                    if let color = Self.parseColor(value) {
                        selectionForeground = color
                    }
                case "palette":
                    // Parse palette entries like "0=#272822"
                    let paletteParts = value.split(separator: "=", maxSplits: 1)
                    if paletteParts.count == 2,
                       let index = Int(paletteParts[0]),
                       let color = Self.parseColor(String(paletteParts[1])) {
                        palette[index] = color
                    }
                case "unfocused-split-opacity":
                    if let opacity = Double(value) {
                        unfocusedSplitOpacity = opacity
                    }
                case "unfocused-split-fill":
                    if let color = Self.parseColor(value) {
                        unfocusedSplitFill = color
                    }
                case "split-divider-color":
                    if let color = Self.parseColor(value) {
                        splitDividerColor = color
                    }
                default:
                    break
                }
            }
        }
    }

    private static func parseColor(_ raw: String) -> NSColor? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hex = NSColor(hex: normalized) {
            return hex
        }
        if normalized == "clear" || normalized == "transparent" {
            return .clear
        }
        if let namedHex = GhosttyX11ColorMap.hexByName[normalized] {
            return NSColor(hex: namedHex)
        }
        return nil
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

// Generated from ghostty/src/terminal/res/rgb.txt.
private enum GhosttyX11ColorMap {
    static let hexByName: [String: String] = [
        "snow": "#FFFAFA",
        "ghost white": "#F8F8FF",
        "ghostwhite": "#F8F8FF",
        "white smoke": "#F5F5F5",
        "whitesmoke": "#F5F5F5",
        "gainsboro": "#DCDCDC",
        "floral white": "#FFFAF0",
        "floralwhite": "#FFFAF0",
        "old lace": "#FDF5E6",
        "oldlace": "#FDF5E6",
        "linen": "#FAF0E6",
        "antique white": "#FAEBD7",
        "antiquewhite": "#FAEBD7",
        "papaya whip": "#FFEFD5",
        "papayawhip": "#FFEFD5",
        "blanched almond": "#FFEBCD",
        "blanchedalmond": "#FFEBCD",
        "bisque": "#FFE4C4",
        "peach puff": "#FFDAB9",
        "peachpuff": "#FFDAB9",
        "navajo white": "#FFDEAD",
        "navajowhite": "#FFDEAD",
        "moccasin": "#FFE4B5",
        "cornsilk": "#FFF8DC",
        "ivory": "#FFFFF0",
        "lemon chiffon": "#FFFACD",
        "lemonchiffon": "#FFFACD",
        "seashell": "#FFF5EE",
        "honeydew": "#F0FFF0",
        "mint cream": "#F5FFFA",
        "mintcream": "#F5FFFA",
        "azure": "#F0FFFF",
        "alice blue": "#F0F8FF",
        "aliceblue": "#F0F8FF",
        "lavender": "#E6E6FA",
        "lavender blush": "#FFF0F5",
        "lavenderblush": "#FFF0F5",
        "misty rose": "#FFE4E1",
        "mistyrose": "#FFE4E1",
        "white": "#FFFFFF",
        "black": "#000000",
        "dark slate gray": "#2F4F4F",
        "darkslategray": "#2F4F4F",
        "dark slate grey": "#2F4F4F",
        "darkslategrey": "#2F4F4F",
        "dim gray": "#696969",
        "dimgray": "#696969",
        "dim grey": "#696969",
        "dimgrey": "#696969",
        "slate gray": "#708090",
        "slategray": "#708090",
        "slate grey": "#708090",
        "slategrey": "#708090",
        "light slate gray": "#778899",
        "lightslategray": "#778899",
        "light slate grey": "#778899",
        "lightslategrey": "#778899",
        "gray": "#BEBEBE",
        "grey": "#BEBEBE",
        "x11 gray": "#BEBEBE",
        "x11gray": "#BEBEBE",
        "x11 grey": "#BEBEBE",
        "x11grey": "#BEBEBE",
        "web gray": "#808080",
        "webgray": "#808080",
        "web grey": "#808080",
        "webgrey": "#808080",
        "light grey": "#D3D3D3",
        "lightgrey": "#D3D3D3",
        "light gray": "#D3D3D3",
        "lightgray": "#D3D3D3",
        "midnight blue": "#191970",
        "midnightblue": "#191970",
        "navy": "#000080",
        "navy blue": "#000080",
        "navyblue": "#000080",
        "cornflower blue": "#6495ED",
        "cornflowerblue": "#6495ED",
        "dark slate blue": "#483D8B",
        "darkslateblue": "#483D8B",
        "slate blue": "#6A5ACD",
        "slateblue": "#6A5ACD",
        "medium slate blue": "#7B68EE",
        "mediumslateblue": "#7B68EE",
        "light slate blue": "#8470FF",
        "lightslateblue": "#8470FF",
        "medium blue": "#0000CD",
        "mediumblue": "#0000CD",
        "royal blue": "#4169E1",
        "royalblue": "#4169E1",
        "blue": "#0000FF",
        "dodger blue": "#1E90FF",
        "dodgerblue": "#1E90FF",
        "deep sky blue": "#00BFFF",
        "deepskyblue": "#00BFFF",
        "sky blue": "#87CEEB",
        "skyblue": "#87CEEB",
        "light sky blue": "#87CEFA",
        "lightskyblue": "#87CEFA",
        "steel blue": "#4682B4",
        "steelblue": "#4682B4",
        "light steel blue": "#B0C4DE",
        "lightsteelblue": "#B0C4DE",
        "light blue": "#ADD8E6",
        "lightblue": "#ADD8E6",
        "powder blue": "#B0E0E6",
        "powderblue": "#B0E0E6",
        "pale turquoise": "#AFEEEE",
        "paleturquoise": "#AFEEEE",
        "dark turquoise": "#00CED1",
        "darkturquoise": "#00CED1",
        "medium turquoise": "#48D1CC",
        "mediumturquoise": "#48D1CC",
        "turquoise": "#40E0D0",
        "cyan": "#00FFFF",
        "aqua": "#00FFFF",
        "light cyan": "#E0FFFF",
        "lightcyan": "#E0FFFF",
        "cadet blue": "#5F9EA0",
        "cadetblue": "#5F9EA0",
        "medium aquamarine": "#66CDAA",
        "mediumaquamarine": "#66CDAA",
        "aquamarine": "#7FFFD4",
        "dark green": "#006400",
        "darkgreen": "#006400",
        "dark olive green": "#556B2F",
        "darkolivegreen": "#556B2F",
        "dark sea green": "#8FBC8F",
        "darkseagreen": "#8FBC8F",
        "sea green": "#2E8B57",
        "seagreen": "#2E8B57",
        "medium sea green": "#3CB371",
        "mediumseagreen": "#3CB371",
        "light sea green": "#20B2AA",
        "lightseagreen": "#20B2AA",
        "pale green": "#98FB98",
        "palegreen": "#98FB98",
        "spring green": "#00FF7F",
        "springgreen": "#00FF7F",
        "lawn green": "#7CFC00",
        "lawngreen": "#7CFC00",
        "green": "#00FF00",
        "lime": "#00FF00",
        "x11 green": "#00FF00",
        "x11green": "#00FF00",
        "web green": "#008000",
        "webgreen": "#008000",
        "chartreuse": "#7FFF00",
        "medium spring green": "#00FA9A",
        "mediumspringgreen": "#00FA9A",
        "green yellow": "#ADFF2F",
        "greenyellow": "#ADFF2F",
        "lime green": "#32CD32",
        "limegreen": "#32CD32",
        "yellow green": "#9ACD32",
        "yellowgreen": "#9ACD32",
        "forest green": "#228B22",
        "forestgreen": "#228B22",
        "olive drab": "#6B8E23",
        "olivedrab": "#6B8E23",
        "dark khaki": "#BDB76B",
        "darkkhaki": "#BDB76B",
        "khaki": "#F0E68C",
        "pale goldenrod": "#EEE8AA",
        "palegoldenrod": "#EEE8AA",
        "light goldenrod yellow": "#FAFAD2",
        "lightgoldenrodyellow": "#FAFAD2",
        "light yellow": "#FFFFE0",
        "lightyellow": "#FFFFE0",
        "yellow": "#FFFF00",
        "gold": "#FFD700",
        "light goldenrod": "#EEDD82",
        "lightgoldenrod": "#EEDD82",
        "goldenrod": "#DAA520",
        "dark goldenrod": "#B8860B",
        "darkgoldenrod": "#B8860B",
        "rosy brown": "#BC8F8F",
        "rosybrown": "#BC8F8F",
        "indian red": "#CD5C5C",
        "indianred": "#CD5C5C",
        "saddle brown": "#8B4513",
        "saddlebrown": "#8B4513",
        "sienna": "#A0522D",
        "peru": "#CD853F",
        "burlywood": "#DEB887",
        "beige": "#F5F5DC",
        "wheat": "#F5DEB3",
        "sandy brown": "#F4A460",
        "sandybrown": "#F4A460",
        "tan": "#D2B48C",
        "chocolate": "#D2691E",
        "firebrick": "#B22222",
        "brown": "#A52A2A",
        "dark salmon": "#E9967A",
        "darksalmon": "#E9967A",
        "salmon": "#FA8072",
        "light salmon": "#FFA07A",
        "lightsalmon": "#FFA07A",
        "orange": "#FFA500",
        "dark orange": "#FF8C00",
        "darkorange": "#FF8C00",
        "coral": "#FF7F50",
        "light coral": "#F08080",
        "lightcoral": "#F08080",
        "tomato": "#FF6347",
        "orange red": "#FF4500",
        "orangered": "#FF4500",
        "red": "#FF0000",
        "hot pink": "#FF69B4",
        "hotpink": "#FF69B4",
        "deep pink": "#FF1493",
        "deeppink": "#FF1493",
        "pink": "#FFC0CB",
        "light pink": "#FFB6C1",
        "lightpink": "#FFB6C1",
        "pale violet red": "#DB7093",
        "palevioletred": "#DB7093",
        "maroon": "#B03060",
        "x11 maroon": "#B03060",
        "x11maroon": "#B03060",
        "web maroon": "#800000",
        "webmaroon": "#800000",
        "medium violet red": "#C71585",
        "mediumvioletred": "#C71585",
        "violet red": "#D02090",
        "violetred": "#D02090",
        "magenta": "#FF00FF",
        "fuchsia": "#FF00FF",
        "violet": "#EE82EE",
        "plum": "#DDA0DD",
        "orchid": "#DA70D6",
        "medium orchid": "#BA55D3",
        "mediumorchid": "#BA55D3",
        "dark orchid": "#9932CC",
        "darkorchid": "#9932CC",
        "dark violet": "#9400D3",
        "darkviolet": "#9400D3",
        "blue violet": "#8A2BE2",
        "blueviolet": "#8A2BE2",
        "purple": "#A020F0",
        "x11 purple": "#A020F0",
        "x11purple": "#A020F0",
        "web purple": "#800080",
        "webpurple": "#800080",
        "medium purple": "#9370DB",
        "mediumpurple": "#9370DB",
        "thistle": "#D8BFD8",
        "snow1": "#FFFAFA",
        "snow2": "#EEE9E9",
        "snow3": "#CDC9C9",
        "snow4": "#8B8989",
        "seashell1": "#FFF5EE",
        "seashell2": "#EEE5DE",
        "seashell3": "#CDC5BF",
        "seashell4": "#8B8682",
        "antiquewhite1": "#FFEFDB",
        "antiquewhite2": "#EEDFCC",
        "antiquewhite3": "#CDC0B0",
        "antiquewhite4": "#8B8378",
        "bisque1": "#FFE4C4",
        "bisque2": "#EED5B7",
        "bisque3": "#CDB79E",
        "bisque4": "#8B7D6B",
        "peachpuff1": "#FFDAB9",
        "peachpuff2": "#EECBAD",
        "peachpuff3": "#CDAF95",
        "peachpuff4": "#8B7765",
        "navajowhite1": "#FFDEAD",
        "navajowhite2": "#EECFA1",
        "navajowhite3": "#CDB38B",
        "navajowhite4": "#8B795E",
        "lemonchiffon1": "#FFFACD",
        "lemonchiffon2": "#EEE9BF",
        "lemonchiffon3": "#CDC9A5",
        "lemonchiffon4": "#8B8970",
        "cornsilk1": "#FFF8DC",
        "cornsilk2": "#EEE8CD",
        "cornsilk3": "#CDC8B1",
        "cornsilk4": "#8B8878",
        "ivory1": "#FFFFF0",
        "ivory2": "#EEEEE0",
        "ivory3": "#CDCDC1",
        "ivory4": "#8B8B83",
        "honeydew1": "#F0FFF0",
        "honeydew2": "#E0EEE0",
        "honeydew3": "#C1CDC1",
        "honeydew4": "#838B83",
        "lavenderblush1": "#FFF0F5",
        "lavenderblush2": "#EEE0E5",
        "lavenderblush3": "#CDC1C5",
        "lavenderblush4": "#8B8386",
        "mistyrose1": "#FFE4E1",
        "mistyrose2": "#EED5D2",
        "mistyrose3": "#CDB7B5",
        "mistyrose4": "#8B7D7B",
        "azure1": "#F0FFFF",
        "azure2": "#E0EEEE",
        "azure3": "#C1CDCD",
        "azure4": "#838B8B",
        "slateblue1": "#836FFF",
        "slateblue2": "#7A67EE",
        "slateblue3": "#6959CD",
        "slateblue4": "#473C8B",
        "royalblue1": "#4876FF",
        "royalblue2": "#436EEE",
        "royalblue3": "#3A5FCD",
        "royalblue4": "#27408B",
        "blue1": "#0000FF",
        "blue2": "#0000EE",
        "blue3": "#0000CD",
        "blue4": "#00008B",
        "dodgerblue1": "#1E90FF",
        "dodgerblue2": "#1C86EE",
        "dodgerblue3": "#1874CD",
        "dodgerblue4": "#104E8B",
        "steelblue1": "#63B8FF",
        "steelblue2": "#5CACEE",
        "steelblue3": "#4F94CD",
        "steelblue4": "#36648B",
        "deepskyblue1": "#00BFFF",
        "deepskyblue2": "#00B2EE",
        "deepskyblue3": "#009ACD",
        "deepskyblue4": "#00688B",
        "skyblue1": "#87CEFF",
        "skyblue2": "#7EC0EE",
        "skyblue3": "#6CA6CD",
        "skyblue4": "#4A708B",
        "lightskyblue1": "#B0E2FF",
        "lightskyblue2": "#A4D3EE",
        "lightskyblue3": "#8DB6CD",
        "lightskyblue4": "#607B8B",
        "slategray1": "#C6E2FF",
        "slategray2": "#B9D3EE",
        "slategray3": "#9FB6CD",
        "slategray4": "#6C7B8B",
        "lightsteelblue1": "#CAE1FF",
        "lightsteelblue2": "#BCD2EE",
        "lightsteelblue3": "#A2B5CD",
        "lightsteelblue4": "#6E7B8B",
        "lightblue1": "#BFEFFF",
        "lightblue2": "#B2DFEE",
        "lightblue3": "#9AC0CD",
        "lightblue4": "#68838B",
        "lightcyan1": "#E0FFFF",
        "lightcyan2": "#D1EEEE",
        "lightcyan3": "#B4CDCD",
        "lightcyan4": "#7A8B8B",
        "paleturquoise1": "#BBFFFF",
        "paleturquoise2": "#AEEEEE",
        "paleturquoise3": "#96CDCD",
        "paleturquoise4": "#668B8B",
        "cadetblue1": "#98F5FF",
        "cadetblue2": "#8EE5EE",
        "cadetblue3": "#7AC5CD",
        "cadetblue4": "#53868B",
        "turquoise1": "#00F5FF",
        "turquoise2": "#00E5EE",
        "turquoise3": "#00C5CD",
        "turquoise4": "#00868B",
        "cyan1": "#00FFFF",
        "cyan2": "#00EEEE",
        "cyan3": "#00CDCD",
        "cyan4": "#008B8B",
        "darkslategray1": "#97FFFF",
        "darkslategray2": "#8DEEEE",
        "darkslategray3": "#79CDCD",
        "darkslategray4": "#528B8B",
        "aquamarine1": "#7FFFD4",
        "aquamarine2": "#76EEC6",
        "aquamarine3": "#66CDAA",
        "aquamarine4": "#458B74",
        "darkseagreen1": "#C1FFC1",
        "darkseagreen2": "#B4EEB4",
        "darkseagreen3": "#9BCD9B",
        "darkseagreen4": "#698B69",
        "seagreen1": "#54FF9F",
        "seagreen2": "#4EEE94",
        "seagreen3": "#43CD80",
        "seagreen4": "#2E8B57",
        "palegreen1": "#9AFF9A",
        "palegreen2": "#90EE90",
        "palegreen3": "#7CCD7C",
        "palegreen4": "#548B54",
        "springgreen1": "#00FF7F",
        "springgreen2": "#00EE76",
        "springgreen3": "#00CD66",
        "springgreen4": "#008B45",
        "green1": "#00FF00",
        "green2": "#00EE00",
        "green3": "#00CD00",
        "green4": "#008B00",
        "chartreuse1": "#7FFF00",
        "chartreuse2": "#76EE00",
        "chartreuse3": "#66CD00",
        "chartreuse4": "#458B00",
        "olivedrab1": "#C0FF3E",
        "olivedrab2": "#B3EE3A",
        "olivedrab3": "#9ACD32",
        "olivedrab4": "#698B22",
        "darkolivegreen1": "#CAFF70",
        "darkolivegreen2": "#BCEE68",
        "darkolivegreen3": "#A2CD5A",
        "darkolivegreen4": "#6E8B3D",
        "khaki1": "#FFF68F",
        "khaki2": "#EEE685",
        "khaki3": "#CDC673",
        "khaki4": "#8B864E",
        "lightgoldenrod1": "#FFEC8B",
        "lightgoldenrod2": "#EEDC82",
        "lightgoldenrod3": "#CDBE70",
        "lightgoldenrod4": "#8B814C",
        "lightyellow1": "#FFFFE0",
        "lightyellow2": "#EEEED1",
        "lightyellow3": "#CDCDB4",
        "lightyellow4": "#8B8B7A",
        "yellow1": "#FFFF00",
        "yellow2": "#EEEE00",
        "yellow3": "#CDCD00",
        "yellow4": "#8B8B00",
        "gold1": "#FFD700",
        "gold2": "#EEC900",
        "gold3": "#CDAD00",
        "gold4": "#8B7500",
        "goldenrod1": "#FFC125",
        "goldenrod2": "#EEB422",
        "goldenrod3": "#CD9B1D",
        "goldenrod4": "#8B6914",
        "darkgoldenrod1": "#FFB90F",
        "darkgoldenrod2": "#EEAD0E",
        "darkgoldenrod3": "#CD950C",
        "darkgoldenrod4": "#8B6508",
        "rosybrown1": "#FFC1C1",
        "rosybrown2": "#EEB4B4",
        "rosybrown3": "#CD9B9B",
        "rosybrown4": "#8B6969",
        "indianred1": "#FF6A6A",
        "indianred2": "#EE6363",
        "indianred3": "#CD5555",
        "indianred4": "#8B3A3A",
        "sienna1": "#FF8247",
        "sienna2": "#EE7942",
        "sienna3": "#CD6839",
        "sienna4": "#8B4726",
        "burlywood1": "#FFD39B",
        "burlywood2": "#EEC591",
        "burlywood3": "#CDAA7D",
        "burlywood4": "#8B7355",
        "wheat1": "#FFE7BA",
        "wheat2": "#EED8AE",
        "wheat3": "#CDBA96",
        "wheat4": "#8B7E66",
        "tan1": "#FFA54F",
        "tan2": "#EE9A49",
        "tan3": "#CD853F",
        "tan4": "#8B5A2B",
        "chocolate1": "#FF7F24",
        "chocolate2": "#EE7621",
        "chocolate3": "#CD661D",
        "chocolate4": "#8B4513",
        "firebrick1": "#FF3030",
        "firebrick2": "#EE2C2C",
        "firebrick3": "#CD2626",
        "firebrick4": "#8B1A1A",
        "brown1": "#FF4040",
        "brown2": "#EE3B3B",
        "brown3": "#CD3333",
        "brown4": "#8B2323",
        "salmon1": "#FF8C69",
        "salmon2": "#EE8262",
        "salmon3": "#CD7054",
        "salmon4": "#8B4C39",
        "lightsalmon1": "#FFA07A",
        "lightsalmon2": "#EE9572",
        "lightsalmon3": "#CD8162",
        "lightsalmon4": "#8B5742",
        "orange1": "#FFA500",
        "orange2": "#EE9A00",
        "orange3": "#CD8500",
        "orange4": "#8B5A00",
        "darkorange1": "#FF7F00",
        "darkorange2": "#EE7600",
        "darkorange3": "#CD6600",
        "darkorange4": "#8B4500",
        "coral1": "#FF7256",
        "coral2": "#EE6A50",
        "coral3": "#CD5B45",
        "coral4": "#8B3E2F",
        "tomato1": "#FF6347",
        "tomato2": "#EE5C42",
        "tomato3": "#CD4F39",
        "tomato4": "#8B3626",
        "orangered1": "#FF4500",
        "orangered2": "#EE4000",
        "orangered3": "#CD3700",
        "orangered4": "#8B2500",
        "red1": "#FF0000",
        "red2": "#EE0000",
        "red3": "#CD0000",
        "red4": "#8B0000",
        "deeppink1": "#FF1493",
        "deeppink2": "#EE1289",
        "deeppink3": "#CD1076",
        "deeppink4": "#8B0A50",
        "hotpink1": "#FF6EB4",
        "hotpink2": "#EE6AA7",
        "hotpink3": "#CD6090",
        "hotpink4": "#8B3A62",
        "pink1": "#FFB5C5",
        "pink2": "#EEA9B8",
        "pink3": "#CD919E",
        "pink4": "#8B636C",
        "lightpink1": "#FFAEB9",
        "lightpink2": "#EEA2AD",
        "lightpink3": "#CD8C95",
        "lightpink4": "#8B5F65",
        "palevioletred1": "#FF82AB",
        "palevioletred2": "#EE799F",
        "palevioletred3": "#CD6889",
        "palevioletred4": "#8B475D",
        "maroon1": "#FF34B3",
        "maroon2": "#EE30A7",
        "maroon3": "#CD2990",
        "maroon4": "#8B1C62",
        "violetred1": "#FF3E96",
        "violetred2": "#EE3A8C",
        "violetred3": "#CD3278",
        "violetred4": "#8B2252",
        "magenta1": "#FF00FF",
        "magenta2": "#EE00EE",
        "magenta3": "#CD00CD",
        "magenta4": "#8B008B",
        "orchid1": "#FF83FA",
        "orchid2": "#EE7AE9",
        "orchid3": "#CD69C9",
        "orchid4": "#8B4789",
        "plum1": "#FFBBFF",
        "plum2": "#EEAEEE",
        "plum3": "#CD96CD",
        "plum4": "#8B668B",
        "mediumorchid1": "#E066FF",
        "mediumorchid2": "#D15FEE",
        "mediumorchid3": "#B452CD",
        "mediumorchid4": "#7A378B",
        "darkorchid1": "#BF3EFF",
        "darkorchid2": "#B23AEE",
        "darkorchid3": "#9A32CD",
        "darkorchid4": "#68228B",
        "purple1": "#9B30FF",
        "purple2": "#912CEE",
        "purple3": "#7D26CD",
        "purple4": "#551A8B",
        "mediumpurple1": "#AB82FF",
        "mediumpurple2": "#9F79EE",
        "mediumpurple3": "#8968CD",
        "mediumpurple4": "#5D478B",
        "thistle1": "#FFE1FF",
        "thistle2": "#EED2EE",
        "thistle3": "#CDB5CD",
        "thistle4": "#8B7B8B",
        "gray0": "#000000",
        "grey0": "#000000",
        "gray1": "#030303",
        "grey1": "#030303",
        "gray2": "#050505",
        "grey2": "#050505",
        "gray3": "#080808",
        "grey3": "#080808",
        "gray4": "#0A0A0A",
        "grey4": "#0A0A0A",
        "gray5": "#0D0D0D",
        "grey5": "#0D0D0D",
        "gray6": "#0F0F0F",
        "grey6": "#0F0F0F",
        "gray7": "#121212",
        "grey7": "#121212",
        "gray8": "#141414",
        "grey8": "#141414",
        "gray9": "#171717",
        "grey9": "#171717",
        "gray10": "#1A1A1A",
        "grey10": "#1A1A1A",
        "gray11": "#1C1C1C",
        "grey11": "#1C1C1C",
        "gray12": "#1F1F1F",
        "grey12": "#1F1F1F",
        "gray13": "#212121",
        "grey13": "#212121",
        "gray14": "#242424",
        "grey14": "#242424",
        "gray15": "#262626",
        "grey15": "#262626",
        "gray16": "#292929",
        "grey16": "#292929",
        "gray17": "#2B2B2B",
        "grey17": "#2B2B2B",
        "gray18": "#2E2E2E",
        "grey18": "#2E2E2E",
        "gray19": "#303030",
        "grey19": "#303030",
        "gray20": "#333333",
        "grey20": "#333333",
        "gray21": "#363636",
        "grey21": "#363636",
        "gray22": "#383838",
        "grey22": "#383838",
        "gray23": "#3B3B3B",
        "grey23": "#3B3B3B",
        "gray24": "#3D3D3D",
        "grey24": "#3D3D3D",
        "gray25": "#404040",
        "grey25": "#404040",
        "gray26": "#424242",
        "grey26": "#424242",
        "gray27": "#454545",
        "grey27": "#454545",
        "gray28": "#474747",
        "grey28": "#474747",
        "gray29": "#4A4A4A",
        "grey29": "#4A4A4A",
        "gray30": "#4D4D4D",
        "grey30": "#4D4D4D",
        "gray31": "#4F4F4F",
        "grey31": "#4F4F4F",
        "gray32": "#525252",
        "grey32": "#525252",
        "gray33": "#545454",
        "grey33": "#545454",
        "gray34": "#575757",
        "grey34": "#575757",
        "gray35": "#595959",
        "grey35": "#595959",
        "gray36": "#5C5C5C",
        "grey36": "#5C5C5C",
        "gray37": "#5E5E5E",
        "grey37": "#5E5E5E",
        "gray38": "#616161",
        "grey38": "#616161",
        "gray39": "#636363",
        "grey39": "#636363",
        "gray40": "#666666",
        "grey40": "#666666",
        "gray41": "#696969",
        "grey41": "#696969",
        "gray42": "#6B6B6B",
        "grey42": "#6B6B6B",
        "gray43": "#6E6E6E",
        "grey43": "#6E6E6E",
        "gray44": "#707070",
        "grey44": "#707070",
        "gray45": "#737373",
        "grey45": "#737373",
        "gray46": "#757575",
        "grey46": "#757575",
        "gray47": "#787878",
        "grey47": "#787878",
        "gray48": "#7A7A7A",
        "grey48": "#7A7A7A",
        "gray49": "#7D7D7D",
        "grey49": "#7D7D7D",
        "gray50": "#7F7F7F",
        "grey50": "#7F7F7F",
        "gray51": "#828282",
        "grey51": "#828282",
        "gray52": "#858585",
        "grey52": "#858585",
        "gray53": "#878787",
        "grey53": "#878787",
        "gray54": "#8A8A8A",
        "grey54": "#8A8A8A",
        "gray55": "#8C8C8C",
        "grey55": "#8C8C8C",
        "gray56": "#8F8F8F",
        "grey56": "#8F8F8F",
        "gray57": "#919191",
        "grey57": "#919191",
        "gray58": "#949494",
        "grey58": "#949494",
        "gray59": "#969696",
        "grey59": "#969696",
        "gray60": "#999999",
        "grey60": "#999999",
        "gray61": "#9C9C9C",
        "grey61": "#9C9C9C",
        "gray62": "#9E9E9E",
        "grey62": "#9E9E9E",
        "gray63": "#A1A1A1",
        "grey63": "#A1A1A1",
        "gray64": "#A3A3A3",
        "grey64": "#A3A3A3",
        "gray65": "#A6A6A6",
        "grey65": "#A6A6A6",
        "gray66": "#A8A8A8",
        "grey66": "#A8A8A8",
        "gray67": "#ABABAB",
        "grey67": "#ABABAB",
        "gray68": "#ADADAD",
        "grey68": "#ADADAD",
        "gray69": "#B0B0B0",
        "grey69": "#B0B0B0",
        "gray70": "#B3B3B3",
        "grey70": "#B3B3B3",
        "gray71": "#B5B5B5",
        "grey71": "#B5B5B5",
        "gray72": "#B8B8B8",
        "grey72": "#B8B8B8",
        "gray73": "#BABABA",
        "grey73": "#BABABA",
        "gray74": "#BDBDBD",
        "grey74": "#BDBDBD",
        "gray75": "#BFBFBF",
        "grey75": "#BFBFBF",
        "gray76": "#C2C2C2",
        "grey76": "#C2C2C2",
        "gray77": "#C4C4C4",
        "grey77": "#C4C4C4",
        "gray78": "#C7C7C7",
        "grey78": "#C7C7C7",
        "gray79": "#C9C9C9",
        "grey79": "#C9C9C9",
        "gray80": "#CCCCCC",
        "grey80": "#CCCCCC",
        "gray81": "#CFCFCF",
        "grey81": "#CFCFCF",
        "gray82": "#D1D1D1",
        "grey82": "#D1D1D1",
        "gray83": "#D4D4D4",
        "grey83": "#D4D4D4",
        "gray84": "#D6D6D6",
        "grey84": "#D6D6D6",
        "gray85": "#D9D9D9",
        "grey85": "#D9D9D9",
        "gray86": "#DBDBDB",
        "grey86": "#DBDBDB",
        "gray87": "#DEDEDE",
        "grey87": "#DEDEDE",
        "gray88": "#E0E0E0",
        "grey88": "#E0E0E0",
        "gray89": "#E3E3E3",
        "grey89": "#E3E3E3",
        "gray90": "#E5E5E5",
        "grey90": "#E5E5E5",
        "gray91": "#E8E8E8",
        "grey91": "#E8E8E8",
        "gray92": "#EBEBEB",
        "grey92": "#EBEBEB",
        "gray93": "#EDEDED",
        "grey93": "#EDEDED",
        "gray94": "#F0F0F0",
        "grey94": "#F0F0F0",
        "gray95": "#F2F2F2",
        "grey95": "#F2F2F2",
        "gray96": "#F5F5F5",
        "grey96": "#F5F5F5",
        "gray97": "#F7F7F7",
        "grey97": "#F7F7F7",
        "gray98": "#FAFAFA",
        "grey98": "#FAFAFA",
        "gray99": "#FCFCFC",
        "grey99": "#FCFCFC",
        "gray100": "#FFFFFF",
        "grey100": "#FFFFFF",
        "dark grey": "#A9A9A9",
        "darkgrey": "#A9A9A9",
        "dark gray": "#A9A9A9",
        "darkgray": "#A9A9A9",
        "dark blue": "#00008B",
        "darkblue": "#00008B",
        "dark cyan": "#008B8B",
        "darkcyan": "#008B8B",
        "dark magenta": "#8B008B",
        "darkmagenta": "#8B008B",
        "dark red": "#8B0000",
        "darkred": "#8B0000",
        "light green": "#90EE90",
        "lightgreen": "#90EE90",
        "crimson": "#DC143C",
        "indigo": "#4B0082",
        "olive": "#808000",
        "rebecca purple": "#663399",
        "rebeccapurple": "#663399",
        "silver": "#C0C0C0",
        "teal": "#008080",
    ]
}
