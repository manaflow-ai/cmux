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

    /// WCAG contrast ratio against `other` (both treated as opaque).
    func contrast(with other: HomeColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `self` (opaque) moved the least toward black or white, away from
    /// `surface`, until it reaches `minimum` contrast on `surface`. A colour
    /// that already meets it comes back unchanged, so themes keep their hues.
    func readable(on surface: HomeColor, minimum: Double = HomePalette.minimumTextContrast) -> HomeColor {
        let opaque = with(alpha: 1)
        guard opaque.contrast(with: surface) < minimum else { return opaque }
        let towardWhite = surface.contrast(with: .gray255(255)) >= surface.contrast(with: .gray255(0))
        let target: HomeColor = towardWhite ? .gray255(255) : .gray255(0)
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if opaque.mixed(with: target, mid).contrast(with: surface) >= minimum { hi = mid } else { lo = mid }
        }
        return opaque.mixed(with: target, hi)
    }

    /// The faintest step from `surface` toward `self` (opaque) that reaches
    /// `minimum` contrast on `surface`: a boundary ink that keeps the theme's
    /// hue and is as soft as WCAG 1.4.11 (3:1 for a component's edge) allows.
    func edge(on surface: HomeColor, minimum: Double = HomePalette.minimumEdgeContrast) -> HomeColor {
        let ink = with(alpha: 1), base = surface.with(alpha: 1)
        guard ink.contrast(with: base) > minimum else { return ink }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if base.mixed(with: ink, mid).contrast(with: base) >= minimum { hi = mid } else { lo = mid }
        }
        return base.mixed(with: ink, hi)
    }

    /// Text on this colour: white while it keeps 3:1 (Messages' white on
    /// its blue is 3.7:1; saturated blues read better white than WCAG's
    /// black pick), else white or black, whichever has the higher contrast.
    public var readableText: HomeColor {
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
    /// The field's fill: the page itself or lighter on a light theme
    /// (Messages' white field), a small lift of the page on a dark one.
    public var composeGlass: HomeColor
    /// The field's hairline edge (a soft ink of the theme's text on a light
    /// theme, where a black edge reads as a dark box).
    public var composeStroke: HomeColor
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

    /// The least WCAG contrast of any text the renderer draws on its surface
    /// (AA body text): typed text and the placeholder on the field, names,
    /// receipts and captions on the page, the Chief's text on its bubble.
    public static let minimumTextContrast: Double = 4.5

    /// The least WCAG contrast of the field's edge against the page (1.4.11,
    /// non-text: a component's boundary needs 3:1) on a light theme, where the
    /// field's white fill is otherwise as pale as the page.
    public static let minimumEdgeContrast: Double = 3

    /// The palette for `theme`. `active` false is the palette of a window
    /// that is not key: lighter neutrals and an accent mixed toward grey.
    public static func themed(_ theme: Theme, active: Bool = true) -> HomePalette {
        let bg = theme.background, fg = theme.foreground
        func n(_ t: CGFloat) -> HomeColor { bg.mixed(with: fg, t) }
        let accent = active ? theme.accent : theme.accent.mixed(with: n(0.5), 0.35)
        let gradient = shading.map { GradientStop(location: $0.0, color: accent.scaled($0.1)) }
        let light = bg.luminance > 0.5
        let palette = HomePalette(
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
            composeGlass: light ? bg.mixed(with: .gray255(255), 0.7) : n(0.13),
            composeStroke: light ? fg.edge(on: active ? bg : n(0.022)) : .gray255(0, alpha: 0.6),
            placeholder: n(0.37),
            morphUnderlay: n(0.113),
            typingDot: n(0.248),
            typingDotHighlight: n(0.426)
        )
        return palette.withReadableText()
    }

    /// Every text colour raised to ``minimumTextContrast`` on the surface it
    /// is drawn on; colours that already meet it are kept as they are.
    func withReadableText() -> HomePalette {
        var p = self
        let field = composeGlass.with(alpha: 1)
        p.incomingText = incomingText.readable(on: incomingBubble).readable(on: field)
        p.placeholder = placeholder.readable(on: field)
        p.secondaryText = secondaryText.readable(on: background.with(alpha: 1))
        return p
    }

    /// How the Chief chat's bubbles look (Settings > Chief > Chief Chat >
    /// Bubble Style, `home.chiefBubbleStyle`; Leo 2026-10-19: iMessage's blue
    /// stays the default, the theme's colours are the option).
    public enum BubbleStyle: Sendable, Hashable {
        /// The default: Messages' blue for the person and its grey for the Chief (`iMessageStyled`).
        case iMessage
        /// The bubbles take the theme's colours (`themeStyled`).
        case theme
    }

    /// The theme's look (the opt-in style). The person's bubbles are `sent` (the
    /// theme's accent and the text on it) when the theme names an accent, else
    /// a neutral step of the theme's own colours; the Chief's sit on the
    /// theme's surface (`themed`). One flat colour: the viewport shading is
    /// Messages' blue, and it reads as a stain on a grey.
    public static func themeStyled(_ theme: Theme, sent: (fill: HomeColor, text: HomeColor)? = nil, active: Bool = true) -> HomePalette {
        var palette = themed(theme, active: active)
        let bg = theme.background, fg = theme.foreground
        let fill = sent?.fill ?? bg.mixed(with: fg, 0.22)
        let shown = active ? fill : fill.mixed(with: bg.mixed(with: fg, 0.5), 0.35)
        palette.outgoingGradient = [GradientStop(location: 0, color: shown), GradientStop(location: 1, color: shown)]
        palette.outgoingText = sent?.text ?? fg
        // The caret is the accent, or the theme's text with none (a grey caret would vanish in the field).
        palette.caret = sent?.fill ?? fg
        return palette.withReadableText()
    }

    /// Messages' look (the default style): its measured grey under the Chief's
    /// bubbles and its text colours, light or dark with the theme. The
    /// person's bubbles are `theme.accent` here; the host passes Messages'
    /// blue, and the renderer draws MessagesLab's measured blue and gradient
    /// for it (`measuredAccent`).
    public static func iMessageStyled(_ theme: Theme, active: Bool = true) -> HomePalette {
        var palette = themed(theme, active: active)
        // Messages' key and non-key windows are the same greys (MessagesLab, macOS 27, 2026-10-05 and 10-09).
        let light = theme.background.luminance > 0.5
        palette.incomingBubble = light ? .rgb255(233, 233, 235) : .rgb255(59, 59, 61)
        palette.incomingText = .gray255(light ? 36 : 225)
        palette.secondaryText = .gray255(light ? 134 : 154)
        palette.badge = palette.incomingBubble
        return palette.withReadableText()
    }

    /// The outgoing colour at a fraction of the viewport height.
    func outgoing(at fraction: CGFloat) -> HomeColor {
        let s = outgoingGradient
        guard let first = s.first else { return .gray255(0) }
        guard s.count > 1 else { return first.color }
        // The first inner stop at or past `fraction`, else the last stop.
        let upper = s.dropFirst().dropLast().firstIndex(where: { $0.location >= fraction }) ?? s.count - 1
        guard let a = s[checked: upper - 1], let b = s[checked: upper] else { return first.color }
        let f = max(0, min(1, (fraction - a.location) / max(1e-6, b.location - a.location)))
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        return HomeColor(red: mix(a.color.red, b.color.red), green: mix(a.color.green, b.color.green),
                         blue: mix(a.color.blue, b.color.blue), alpha: mix(a.color.alpha, b.color.alpha))
    }
}
