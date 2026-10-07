public import Foundation

/// The gallery's controls: one value set for both hosts. The names, values and URL query keys
/// are the web gallery's (`webviews/src/gallery/env.ts`); `schemas/gallery/env-vectors.json`
/// holds query/value pairs that both sides' tests replay, so a link means the same in each.
///
/// ```swift
/// let env = GalleryEnvironment(query: ["scheme": "light", "width": "narrow"])
/// env.widthPoints(presets: GalleryEnvironment.nativeWidths) // 320
/// ```
public nonisolated struct GalleryEnvironment: Hashable, Sendable {
    /// The window appearance; picks ``dark`` or ``light`` as the Ghostty theme.
    public enum Scheme: String, Hashable, Sendable, CaseIterable { case dark, light }
    /// Native only: the text size.
    public enum DynamicSize: String, Hashable, Sendable, CaseIterable { case standard = "default", large, xlarge }
    /// Native only: whether the window is key.
    public enum WindowKey: String, Hashable, Sendable, CaseIterable { case key, inactive }
    public enum Density: String, Hashable, Sendable, CaseIterable { case comfortable, compact }
    /// A named width preset (the entry's or the host's), or points.
    public enum Width: Hashable, Sendable {
        case narrow, normal, wide
        case points(Double)
    }

    public var locale: String
    public var scheme: Scheme
    /// The Ghostty theme for each scheme, as `theme = light:A,dark:B` names them.
    public var dark: String
    public var light: String
    /// Empty: the view's own font.
    public var font: String
    /// Points; 0 is the view's own size.
    public var size: Double
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
        scheme = .dark
        dark = "Apple System Colors"
        light = "Apple System Colors Light"
        font = ""
        size = 0
        density = .comfortable
        scale = 1
        width = .normal
        height = 0
        reducedMotion = false
        highContrast = false
        dynamicSize = .standard
        windowKey = .key
    }

    /// The controls a URL query names; anything missing or invalid keeps its default (`readEnv`).
    ///
    /// - Parameter query: Query items by name.
    public init(query: [String: String]) {
        self.init()
        if let value = query["locale"], Self.locales.contains(value) { locale = value }
        if query["scheme"] == "light" { scheme = .light }
        if let value = query["dark"], !value.isEmpty { dark = value }
        if let value = query["light"], !value.isEmpty { light = value }
        font = String((query["font"] ?? "").prefix(200))
        size = Self.number(query["size"], fallback: 0, in: 0...40)
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
    }

    /// The Ghostty theme the scheme shows.
    public var activeTheme: String { scheme == .dark ? dark : light }

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
