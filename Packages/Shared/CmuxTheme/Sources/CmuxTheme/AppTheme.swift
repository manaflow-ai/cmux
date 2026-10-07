import Foundation

/// The app theme: cmux's chrome tokens derived from a terminal palette, so
/// every bundled Ghostty theme also works as the app theme. A line-for-line
/// port of the shared contract in `webviews/src/theme/appTheme.ts` (and its
/// color math, `color.ts`); `schemas/theme/app-theme-vectors.json` holds the
/// web module's output for a sample of themes, and the Swift tests replay it.
///
/// Every token is opaque `#rrggbb`. Each pair in ``contract`` meets its WCAG 2
/// minimum: 4.5:1 for text, 3:1 for UI marks. The accent hue comes from the
/// palette (ANSI 4 when it has color, else the most colorful slot); a
/// palette with no color gets a neutral accent. No hue is hard-coded.
///
/// ```swift
/// let app = AppTheme.derive(from: ThemeInput(terminalTheme: .monokai))
/// let accent = app[.accent]
/// ```
public struct AppTheme: Hashable, Sendable {
    /// One token of the contract.
    public enum Token: String, CaseIterable, Hashable, Sendable {
        case window, sidebar, content, elevated, control, hover, pressed, selection, separator
        case controlStroke, text, textSecondary, icon, accent, onAccent, accentText, focusRing
        case danger, warning, success

        /// The CSS custom property web pages read (`--cmux-app-*`).
        public var variable: String {
            let kebab = rawValue.reduce(into: "") { text, character in
                if character.isUppercase { text += "-" + character.lowercased() } else { text.append(character) }
            }
            return "--cmux-app-\(kebab)"
        }
    }

    /// A foreground/background pair and its WCAG 2 minimum.
    public struct Pair: Hashable, Sendable {
        public let token: Token
        public let on: Token
        public let minimum: Double
    }

    /// Whether the palette is dark (its background darker than its foreground).
    public let isDark: Bool
    /// The palette slot the accent hue came from; nil for a palette without color.
    public let accentSource: Int?
    /// Every token, opaque.
    public let tokens: [Token: ThemeRGB]

    /// The token's color.
    public subscript(token: Token) -> ThemeRGB { tokens[token] ?? .black }

    /// `--cmux-app-*` name to `#rrggbb`.
    public var cssVariables: [String: String] {
        Dictionary(uniqueKeysWithValues: Token.allCases.map { ($0.variable, Self.hex(self[$0])) })
    }

    public static let textMinimum = 4.5
    public static let uiMinimum = 3.0
    /// A slot "has color" from this OKLCH chroma up.
    public static let accentMinimumChroma = 0.05

    private static let plainSurfaces: [Token] = [.window, .sidebar, .content, .elevated]
    private static let textSurfaces: [Token] = plainSurfaces + [.control, .hover, .pressed, .selection]
    private static let statusSurfaces: [Token] = plainSurfaces + [.hover]

    /// Every pair the tokens are used in, with its minimum (the web module's `APP_THEME_CONTRACT`).
    public static let contract: [Pair] = textSurfaces.map { Pair(token: .text, on: $0, minimum: textMinimum) }
        + textSurfaces.map { Pair(token: .textSecondary, on: $0, minimum: textMinimum) }
        + textSurfaces.map { Pair(token: .icon, on: $0, minimum: uiMinimum) }
        + (plainSurfaces + [.control]).map { Pair(token: .controlStroke, on: $0, minimum: uiMinimum) }
        + plainSurfaces.map { Pair(token: .accent, on: $0, minimum: uiMinimum) }
        + plainSurfaces.map { Pair(token: .focusRing, on: $0, minimum: uiMinimum) }
        + [Pair(token: .onAccent, on: .accent, minimum: textMinimum)]
        + (statusSurfaces + [.selection]).map { Pair(token: .accentText, on: $0, minimum: textMinimum) }
        + statusSurfaces.map { Pair(token: .danger, on: $0, minimum: textMinimum) }
        + statusSurfaces.map { Pair(token: .warning, on: $0, minimum: textMinimum) }
        + statusSurfaces.map { Pair(token: .success, on: $0, minimum: textMinimum) }

    /// Every contract pair whose measured ratio is below its minimum (empty for a derived theme).
    public var failures: [Pair] {
        Self.contract.filter { AppColor.contrast(self[$0.token], self[$0.on]) < $0.minimum }
    }

    /// Ghostty's own defaults, for a theme that omits a slot.
    private static let ghosttyDefaultPalette: [UInt32] = [
        0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
        0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
    ]
    /// ANSI 4 first, then the most colorful of these.
    private static let accentFallbackSlots = [12, 5, 13, 6, 14, 2, 10, 3, 11]
    /// Surface tint strengths, tried in order until every pair passes (mid-luminance backgrounds).
    private static let tintScales: [Double] = [1, 0.7, 0.45, 0.25, 0.1, 0]

    /// The tokens of a terminal theme's colors.
    public static func derive(from input: ThemeInput) -> AppTheme {
        derive(background: input.background, foreground: input.foreground, palette: input.palette)
    }

    /// The tokens of a terminal palette. Every pair in ``contract`` meets its minimum.
    ///
    /// - Parameters:
    ///   - background: The terminal background (alpha ignored).
    ///   - foreground: The terminal foreground (alpha ignored).
    ///   - palette: ANSI 0...15; a missing slot takes Ghostty's default.
    public static func derive(background: ThemeRGB, foreground: ThemeRGB, palette: [ThemeRGB?]) -> AppTheme {
        let full = ghosttyDefaultPalette.enumerated().map { index, fallback in
            (index < palette.count ? palette[index] : nil).map(\.opaque) ?? ThemeRGB(hex: fallback)
        }
        var theme = derive(background.opaque, foreground.opaque, full, tint: 1)
        for scale in tintScales.dropFirst() where !theme.failures.isEmpty {
            theme = derive(background.opaque, foreground.opaque, full, tint: scale)
        }
        return theme
    }

    /// See ``derive(background:foreground:palette:)``.
    public static func derive(background: ThemeRGB, foreground: ThemeRGB, palette: [ThemeRGB]) -> AppTheme {
        derive(background: background, foreground: foreground, palette: palette.map { Optional($0) })
    }

    /// The palette slot that gives the accent its hue, or nil when no slot has color.
    public static func accentSlot(_ palette: [ThemeRGB]) -> Int? {
        if AppColor.oklch(palette[4]).c >= accentMinimumChroma { return 4 }
        var best: Int?
        var bestChroma = accentMinimumChroma
        for slot in accentFallbackSlots {
            let chroma = AppColor.oklch(palette[slot]).c
            if chroma >= bestChroma + 1e-9 {
                best = slot
                bestChroma = chroma
            }
        }
        return best
    }

    private static func derive(_ bg: ThemeRGB, _ fg: ThemeRGB, _ palette: [ThemeRGB], tint: Double) -> AppTheme {
        let isDark = AppColor.luminance(bg) < AppColor.luminance(fg)
        var t: [Token: ThemeRGB] = [:]
        let q = AppColor.quantized
        t[.window] = q(bg)
        t[.content] = q(bg)
        t[.sidebar] = q(bg.mixed(toward: fg, (isDark ? 0.04 : 0.035) * tint))
        t[.elevated] = q(isDark ? bg.mixed(toward: fg, 0.075 * tint) : bg.mixed(toward: .white, 0.7 * tint))
        t[.control] = q(bg.mixed(toward: fg, (isDark ? 0.1 : 0.065) * tint))
        t[.hover] = q(bg.mixed(toward: fg, (isDark ? 0.06 : 0.045) * tint))
        t[.pressed] = q(bg.mixed(toward: fg, (isDark ? 0.12 : 0.09) * tint))
        t[.separator] = q(bg.mixed(toward: fg, isDark ? 0.13 : 0.11))
        func on(_ names: [Token], _ minimum: Double) -> [AppColor.Constraint] {
            names.map { AppColor.Constraint(on: t[$0]!, minimum: minimum) }
        }

        let slot = accentSlot(palette)
        let onAccentWanted = isDark ? t[.window]! : ThemeRGB.white
        let seed = slot.map { palette[$0] } ?? fg
        let accent = AppColor.fit(seed, on(plainSurfaces, uiMinimum) + [AppColor.Constraint(on: onAccentWanted, minimum: textMinimum)],
                                  prefer: isDark ? .lighter : .darker)
        t[.accent] = accent
        t[.focusRing] = accent
        let onAccentOK = AppColor.meets(onAccentWanted, [AppColor.Constraint(on: accent, minimum: textMinimum)])
        t[.onAccent] = onAccentOK ? onAccentWanted
            : AppColor.fit(isDark ? .black : .white, [AppColor.Constraint(on: accent, minimum: textMinimum)], prefer: nil)
        t[.selection] = q(bg.mixed(toward: accent, (isDark ? 0.26 : 0.16) * tint))

        let text = AppColor.fit(fg, on(textSurfaces, textMinimum), prefer: nil)
        t[.text] = text
        t[.textSecondary] = AppColor.fit(text.mixed(toward: bg, 0.34), on(textSurfaces, textMinimum), prefer: isDark ? .lighter : .darker)
        t[.icon] = AppColor.fit(text.mixed(toward: bg, 0.3), on(textSurfaces, uiMinimum), prefer: isDark ? .lighter : .darker)
        t[.controlStroke] = AppColor.fit(bg.mixed(toward: fg, 0.42), on(plainSurfaces + [.control], uiMinimum),
                                         prefer: isDark ? .lighter : .darker)
        let away: AppColor.Direction = isDark ? .lighter : .darker
        t[.accentText] = AppColor.fit(accent, on(statusSurfaces + [.selection], textMinimum), prefer: away)
        t[.danger] = AppColor.fit(colorful(palette, 1, 9), on(statusSurfaces, textMinimum), prefer: away)
        t[.warning] = AppColor.fit(colorful(palette, 3, 11), on(statusSurfaces, textMinimum), prefer: away)
        t[.success] = AppColor.fit(colorful(palette, 2, 10), on(statusSurfaces, textMinimum), prefer: away)
        return AppTheme(isDark: isDark, accentSource: slot, tokens: t)
    }

    /// The more colorful of a normal and a bright slot.
    private static func colorful(_ palette: [ThemeRGB], _ normal: Int, _ bright: Int) -> ThemeRGB {
        AppColor.oklch(palette[bright]).c > AppColor.oklch(palette[normal]).c + 0.02 ? palette[bright] : palette[normal]
    }

    /// `#rrggbb`, lower case, as the web module writes tokens.
    public static func hex(_ color: ThemeRGB) -> String {
        String(format: "#%02x%02x%02x", AppColor.byte(color.red), AppColor.byte(color.green), AppColor.byte(color.blue))
    }
}

private extension ThemeRGB {
    var opaque: ThemeRGB { withAlpha(1) }
}

/// The app theme's color math (the web module's `color.ts`): WCAG 2 contrast on 8-bit colors and
/// OKLCH lightness moves that keep a color's hue.
struct AppColor {
    struct OKLCH { var l: Double, c: Double, h: Double }
    struct Constraint { let on: ThemeRGB, minimum: Double }
    enum Direction { case lighter, darker }

    static func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    /// The color as its 8-bit hex rounds it.
    static func quantized(_ color: ThemeRGB) -> ThemeRGB {
        ThemeRGB(red: Double(byte(color.red)) / 255, green: Double(byte(color.green)) / 255, blue: Double(byte(color.blue)) / 255)
    }

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func luminance(_ color: ThemeRGB) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func oklch(_ color: ThemeRGB) -> OKLCH {
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        let hue = atan2(bb, a) * 180 / Double.pi
        return OKLCH(l: lightness, c: hypot(a, bb), h: hue < 0 ? hue + 360 : hue)
    }

    private static func toLinear(_ color: OKLCH) -> (Double, Double, Double) {
        let radians = color.h * Double.pi / 180
        let a = color.c * cos(radians), b = color.c * sin(radians)
        let l = pow(color.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(color.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(color.l - 0.0894841775 * a - 1.291485548 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
    }

    private static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        [rgb.0, rgb.1, rgb.2].allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    /// The sRGB color of an OKLCH value; out of gamut, chroma drops until it fits.
    static func fromOKLCH(_ value: OKLCH) -> ThemeRGB {
        let l = min(max(value.l, 0), 1)
        var low = 0.0
        var high = max(value.c, 0)
        if !inGamut(toLinear(OKLCH(l: l, c: high, h: value.h))) {
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if inGamut(toLinear(OKLCH(l: l, c: middle, h: value.h))) { low = middle } else { high = middle }
            }
            high = low
        }
        let rgb = toLinear(OKLCH(l: l, c: high, h: value.h))
        func channel(_ c: Double) -> Double { min(max(gamma(min(max(c, 0), 1)), 0), 1) }
        return ThemeRGB(red: channel(rgb.0), green: channel(rgb.1), blue: channel(rgb.2))
    }

    static func meets(_ color: ThemeRGB, _ constraints: [Constraint]) -> Bool {
        constraints.allSatisfy { contrast(color, $0.on) >= $0.minimum }
    }

    /// `color` with the smallest OKLCH lightness change that meets every constraint (the web `fit`).
    static func fit(_ color: ThemeRGB, _ constraints: [Constraint], prefer: Direction?) -> ThemeRGB {
        let start = quantized(color)
        if meets(start, constraints) { return start }
        let lch = oklch(start)
        let average = constraints.reduce(0) { $0 + luminance($1.on) } / Double(max(constraints.count, 1))
        let first = prefer ?? (average < 0.18 ? .lighter : .darker)
        for direction in [first, first == .lighter ? Direction.darker : .lighter] {
            let pole = direction == .lighter ? 1.0 : 0.0
            func at(_ t: Double) -> ThemeRGB { quantized(fromOKLCH(OKLCH(l: lch.l + (pole - lch.l) * t, c: lch.c, h: lch.h))) }
            guard meets(at(1), constraints) else { continue }
            var low = 0.0, high = 1.0
            for _ in 0..<28 {
                let middle = (low + high) / 2
                if meets(at(middle), constraints) { high = middle } else { low = middle }
            }
            return at(high)
        }
        let white = constraints.map { contrast(.white, $0.on) }.min() ?? 0
        let black = constraints.map { contrast(.black, $0.on) }.min() ?? 0
        return white >= black ? .white : .black
    }
}
