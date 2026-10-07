public import Foundation

/// The gallery's controls: one value set for both hosts. The names, values and URL query keys
/// are the web gallery's (`webviews/src/gallery/env.ts`); `schemas/gallery/env-vectors.json`
/// holds query/value pairs that both sides' tests replay, so a link means the same in each.
///
/// ```swift
/// let env = GalleryEnvironment(query: ["colorScheme": "light", "width": "narrow"])
/// env.widthPoints(presets: GalleryEnvironment.nativeWidths) // 320
/// ```
public nonisolated struct GalleryEnvironment: Hashable, Sendable {
    /// The window appearance; `auto` is the theme's own.
    public enum ColorScheme: String, Hashable, Sendable, CaseIterable { case auto, dark, light }
    /// Native only: the text size.
    public enum DynamicSize: String, Hashable, Sendable, CaseIterable { case standard = "default", large, xlarge }
    /// Native only: whether the window is key.
    public enum WindowKey: String, Hashable, Sendable, CaseIterable { case key, inactive }
    public enum Density: String, Hashable, Sendable, CaseIterable { case comfortable, compact }
    /// `window`: the entry at its real size in a cmux window; `component`: the entry alone.
    public enum Frame: String, Hashable, Sendable, CaseIterable { case window, component }
    /// The panes around the entry in window mode.
    public enum Layout: String, Hashable, Sendable, CaseIterable {
        case one, two
        case agentRight = "agent-right"
    }
    /// A named width preset (the entry's or the host's), or points.
    public enum Width: Hashable, Sendable {
        case narrow, normal, wide
        case points(Double)
    }

    public var locale: String
    /// The Ghostty theme the window shows (a shipped theme's file name).
    public var theme: String
    public var colorScheme: ColorScheme
    /// Empty: the view's own font.
    public var fontFamily: String
    /// Points; 0 is the view's own size.
    public var fontSize: Double
    public var density: Density
    /// Interface scale (DesignSettings.uiScale).
    public var scale: Double
    public var width: Width
    /// Points; 0 fits the view.
    public var height: Double
    public var reducedMotion: Bool
    public var highContrast: Bool
    public var dynamicSize: DynamicSize
    public var windowKey: WindowKey
    public var frame: Frame
    /// A window preset (`16x9`, `air13`, `pro14`, `display27`) or `<width>x<height>`.
    public var window: String
    /// The shell's scale of a window: nil fits the view.
    public var zoom: Double?
    public var layout: Layout

    /// Window presets in points (`WINDOW_PRESETS` in webviews/src/gallery/window.ts).
    public static let windowPresets: [String: (width: Double, height: Double)] = [
        "16x9": (1920, 1080), "air13": (1470, 956), "pro14": (1512, 982), "display27": (2560, 1440),
    ]

    /// Web pane widths (`WIDTHS` in env.ts).
    public static let webWidths: [String: Double] = ["narrow": 420, "normal": 760, "wide": 1200]
    /// Native entries' widths (`NATIVE_WIDTHS` in env.ts).
    public static let nativeWidths: [String: Double] = ["narrow": 320, "normal": 560, "wide": 900]
    /// The 21 shipped languages, then the two pseudo-locales.
    public static let locales = [
        "en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb", "pl", "pt-BR", "ru", "th", "tr",
        "uk", "vi", "zh-Hans", "zh-Hant", "en-XA", "ar-XB",
    ]

    /// The defaults (`DEFAULT_ENV`).
    public init() {
        locale = "en"
        theme = "Apple System Colors"
        colorScheme = .auto
        fontFamily = ""
        fontSize = 0
        density = .comfortable
        scale = 1
        width = .normal
        height = 0
        reducedMotion = false
        highContrast = false
        dynamicSize = .standard
        windowKey = .key
        frame = .window
        window = "16x9"
        zoom = nil
        layout = .one
    }

    /// The controls a URL query names; anything missing or invalid keeps its default (`readEnv`).
    ///
    /// - Parameter query: Query items by name.
    public init(query: [String: String]) {
        self.init()
        if let value = query["locale"], Self.locales.contains(value) { locale = value }
        if let value = query["theme"], !value.isEmpty { theme = value }
        if let value = query["colorScheme"], let parsed = ColorScheme(rawValue: value) { colorScheme = parsed }
        fontFamily = String((query["fontFamily"] ?? "").prefix(200))
        fontSize = Self.number(query["fontSize"], fallback: 0, in: 0...40)
        if query["density"] == "compact" { density = .compact }
        scale = Self.number(query["scale"], fallback: 1, in: 0.5...3)
        switch query["width"] {
        case "narrow": width = .narrow
        case "wide": width = .wide
        case let value? where !value.isEmpty && value.allSatisfy(\.isASCIIDigit):
            width = .points(min(max(Double(value) ?? 760, 240), 3000))
        default: width = .normal
        }
        height = Self.number(query["height"], fallback: 0, in: 0...4000)
        reducedMotion = Self.flag(query["reducedMotion"])
        highContrast = Self.flag(query["highContrast"])
        if let value = query["dynamicSize"], let parsed = DynamicSize(rawValue: value) { dynamicSize = parsed }
        if query["windowKey"] == "inactive" { windowKey = .inactive }
        if query["frame"] == "component" { frame = .component }
        if let value = query["window"],
           Self.windowPresets[value] != nil || value.range(of: #"^\d{3,4}x\d{3,4}$"#, options: .regularExpression) != nil {
            window = value
        }
        if let value = query["zoom"], value != "fit" { zoom = Self.number(value, fallback: 1, in: 0.1...2) }
        if let value = query["layout"], let parsed = Layout(rawValue: value) { layout = parsed }
    }

    /// The window's size in points: a preset, `<width>x<height>`, else 16:9.
    public var windowSize: (width: Double, height: Double) {
        if let preset = Self.windowPresets[window] { return preset }
        let parts = window.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return (1920, 1080) }
        return (min(parts[0], 5120), min(parts[1], 2880))
    }

    /// The width in points under `presets` (an entry's own, else the host's).
    public func widthPoints(presets: [String: Double]) -> Double {
        switch width {
        case .narrow: presets["narrow"] ?? Self.nativeWidths["narrow"] ?? 320
        case .normal: presets["normal"] ?? Self.nativeWidths["normal"] ?? 560
        case .wide: presets["wide"] ?? Self.nativeWidths["wide"] ?? 900
        case let .points(points): points
        }
    }

    private static func flag(_ value: String?) -> Bool { value == "1" || value == "true" }

    private static func number(_ value: String?, fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let value, let parsed = Double(value), parsed.isFinite else { return fallback }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
