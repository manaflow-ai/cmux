public import CoreGraphics
import Foundation

/// An sRGB colour as plain numbers (Sendable and hashable, so it can key the
/// bitmap cache and live in a static default).
public struct HomeColor: Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 0...255 components.
    public static func rgb255(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> HomeColor {
        HomeColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    public static func gray255(_ w: CGFloat, alpha: CGFloat = 1) -> HomeColor { rgb255(w, w, w, alpha: alpha) }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    func with(alpha: CGFloat) -> HomeColor { HomeColor(red: red, green: green, blue: blue, alpha: alpha) }

    /// `self` moved toward `other` by `t` (0 = self, 1 = other).
    func mixed(with other: HomeColor, _ t: CGFloat) -> HomeColor {
        func m(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return HomeColor(red: m(red, other.red), green: m(green, other.green), blue: m(blue, other.blue), alpha: m(alpha, other.alpha))
    }

    /// Brightness scaled by `factor` (alpha kept).
    func scaled(_ factor: CGFloat) -> HomeColor {
        HomeColor(red: min(1, red * factor), green: min(1, green * factor), blue: min(1, blue * factor), alpha: alpha)
    }

    /// Relative luminance (sRGB weights, no linearization; enough to pick black or white text).
    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// WCAG relative luminance (linearized sRGB).
    var relativeLuminance: Double {
        func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// Text on this colour: white while it keeps 3:1 (Messages' white on
    /// its blue is 3.7:1; saturated blues read better white than WCAG's
    /// black pick), else white or black, whichever has the higher contrast.
    var readableText: HomeColor {
        let l = relativeLuminance
        let onWhite = 1.05 / (l + 0.05), onBlack = (l + 0.05) / 0.05
        return onWhite >= 3 || onWhite >= onBlack ? .gray255(255) : .gray255(0)
    }
}

/// Every colour the renderer draws. Hosts build it from the app theme with
/// `themed(_:active:)`: the sent bubble, caret and my tapbacks use the
/// theme's accent, the rest mixes the theme's background and foreground in
/// the proportions measured from the reference design. There is no default
/// palette, so no accent colour is hard-coded here (users pick one in the
/// host's settings, blue included).
public struct HomePalette: Hashable, Sendable {
    public var background: HomeColor
    public var incomingBubble: HomeColor
    public var incomingText: HomeColor
    public var outgoingText: HomeColor
    public var secondaryText: HomeColor
    public var failure: HomeColor
    public var badge: HomeColor
    /// Outgoing bubbles shade with their position in the viewport: stops at
    /// fractions of the viewport height, top to bottom.
    public var outgoingGradient: [GradientStop]
    public var caret: HomeColor
    public var caretAfterSend: HomeColor
    public var composeGlass: HomeColor
    public var placeholder: HomeColor
    /// The grey under the flying bubble while it is translucent (the field's glass).
    public var morphUnderlay: HomeColor
    public var typingDot: HomeColor
    public var typingDotHighlight: HomeColor

    public struct GradientStop: Hashable, Sendable {
        public var location: CGFloat
        public var color: HomeColor

        public init(location: CGFloat, color: HomeColor) {
            self.location = location
            self.color = color
        }
    }

    /// The theme colours a host passes (for example from the Ghostty theme).
    public struct Theme: Hashable, Sendable {
        public var background: HomeColor
        public var foreground: HomeColor
        /// Sent bubbles, the caret and my tapbacks.
        public var accent: HomeColor
        /// A send the owner refused.
        public var failure: HomeColor

        public init(background: HomeColor, foreground: HomeColor, accent: HomeColor, failure: HomeColor) {
            self.background = background
            self.foreground = foreground
            self.accent = accent
            self.failure = failure
        }
    }

    /// Relative brightness of a sent bubble from the top to the bottom of the
    /// viewport, measured from bubble centers of the reference (fraction of the
    /// viewport height, factor against the top colour).
    static let shading: [(CGFloat, CGFloat)] = [
        (0, 1), (0.192, 0.996), (0.259, 0.991), (0.384, 0.978), (0.576, 0.951), (0.716, 0.928),
        (0.768, 0.917), (0.865, 0.896), (0.913, 0.885), (0.941, 0.879), (1, 0.879),
    ]

    /// The palette for `theme`. `active` false is the palette of a window
    /// that is not key: lighter neutrals and an accent mixed toward grey.
    public static func themed(_ theme: Theme, active: Bool = true) -> HomePalette {
        let bg = theme.background, fg = theme.foreground
        func n(_ t: CGFloat) -> HomeColor { bg.mixed(with: fg, t) }
        let accent = active ? theme.accent : theme.accent.mixed(with: n(0.5), 0.35)
        let gradient = shading.map { GradientStop(location: $0.0, color: accent.scaled($0.1)) }
        return HomePalette(
            background: active ? bg : n(0.022),
            incomingBubble: n(active ? 0.104 : 0.148),
            incomingText: n(0.848),
            outgoingText: accent.readableText,
            secondaryText: n(0.535),
            failure: theme.failure,
            badge: n(0.148),
            outgoingGradient: gradient,
            caret: theme.accent,
            caretAfterSend: n(0.443),
            composeGlass: n(0.104),
            placeholder: n(0.37),
            morphUnderlay: n(0.113),
            typingDot: n(0.248),
            typingDotHighlight: n(0.426)
        )
    }

    /// The outgoing colour at a fraction of the viewport height.
    func outgoing(at fraction: CGFloat) -> HomeColor {
        let s = outgoingGradient
        guard let first = s.first else { return .gray255(0) }
        guard s.count > 1 else { return first.color }
        var i = 1
        while i < s.count - 1, s[i].location < fraction { i += 1 }
        let a = s[i - 1], b = s[i]
        let f = max(0, min(1, (fraction - a.location) / max(1e-6, b.location - a.location)))
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        return HomeColor(red: mix(a.color.red, b.color.red), green: mix(a.color.green, b.color.green),
                         blue: mix(a.color.blue, b.color.blue), alpha: mix(a.color.alpha, b.color.alpha))
    }
}
