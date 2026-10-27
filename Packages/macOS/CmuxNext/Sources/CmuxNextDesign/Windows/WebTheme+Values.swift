public import Foundation
public import CmuxNextDesignTokens

// The values and names a ``WebTheme`` payload and its bootstrap script use.
nonisolated extension WebTheme {
    /// The terminal colors a page highlights code with: the scope's opaque background and
    /// readable foreground, and its ANSI palette as the theme names it (the page lifts each
    /// slot only as far as it needs to read).
    public nonisolated struct Terminal: Equatable, Sendable {
        public let type: String
        public let background: String
        public let foreground: String
        public let palette: [String: String]
        /// The terminal's font family (`DesignSettings.effectiveTerminalFontFamily`); nil when
        /// neither cmux.json nor the Ghostty config names one.
        public let fontFamily: String?

        init(_ tokens: ThemeTokens, fontFamily: String?) {
            type = tokens.isDark ? "dark" : "light"
            background = WebTheme.hex(tokens.surfaceBackground)
            foreground = WebTheme.hex(tokens.textPrimary)
            palette = Dictionary(tokens.ansi.prefix(16).enumerated().map { (String($0.offset), WebTheme.hex($0.element)) }, uniquingKeysWith: { first, _ in first })
            self.fontFamily = fontFamily
        }

        var json: [String: Any] {
            ["type": type, "background": background, "foreground": foreground, "palette": palette,
             "fontFamily": fontFamily.map { $0 as Any } ?? NSNull()]
        }
    }

    /// `data-cmux-motion` for `policy`: `off` when the web category, the master switch or speed
    /// is off (the bootstrap stylesheet then ends every transition and animation at once),
    /// `reduced` under Reduce Motion, else `full`.
    public static func motionValue(_ policy: MotionPolicy) -> String {
        guard policy.categoryAnimates else { return "off" }
        return policy.reduceMotion ? "reduced" : "full"
    }

    /// `data-cmux-energy` for `policy`: `saver` under Energy Saver (``MotionPolicy/energySaver``),
    /// else nil (no attribute).
    public static func energyValue(_ policy: MotionPolicy) -> String? {
        policy.energySaver ? "saver" : nil
    }

    /// The script message handler the bootstrap posts the page's field data to: `{v: 1, inp, loaf,
    /// errors}`, slow interactions and long frames in ms and the script errors since the last report
    /// (webviews/src/protocol/perfReport.ts; CmuxNextPages `PagePerfReport` reads it).
    public static let perfHandlerName = "cmuxPagePerf"
    /// The most interactions or long frames one report carries: a fuller list goes out at once.
    public static let perfReportCapacity = 32

    /// `#rrggbb`, opaque (the alpha is dropped).
    static func hex(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return String(format: "#%02x%02x%02x", channel(color.red), channel(color.green), channel(color.blue))
    }

    /// `rgba(r, g, b, a)` with 0-255 channels.
    public static func css(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 1000).rounded() / 1000
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(alpha))"
    }

    /// `color` as pages read it from `css`: each channel rounded to 8 bits, the alpha to 3 decimals.
    public static func cssRounded(_ color: ThemeRGB) -> ThemeRGB {
        func channel(_ value: Double) -> Double { (value * 255).rounded() / 255 }
        return ThemeRGB(red: channel(color.red), green: channel(color.green), blue: channel(color.blue),
                        alpha: (color.alpha * 1000).rounded() / 1000)
    }
}
