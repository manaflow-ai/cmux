#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Measured style metrics. Geometry is in points of a 628x1041 pt window.
enum Fixture {
    static let windowSize = CGSize(width: 628, height: 1041)
    /// The screen scale every bitmap is rasterized at (row bitmaps, the
    /// compose glass, the morph, canvases). Set from the window's screen and
    /// on every display change (`MessagesWindowView.setRenderScale`); a change
    /// bumps `paletteGeneration`, which drops every cached row bitmap. Test
    /// renders (capture, live grab) keep 2, the reference's scale.
    static var renderScale: CGFloat = 2 { didSet { if renderScale != oldValue { paletteGeneration += 1 } } }

    // MARK: Style

    static let bodyFont = UIFont.systemFont(ofSize: 13)
    static let lineHeight: CGFloat = 16
    /// Messages draws body text ~0.27% tighter than Core Text's default
    /// advances (measured drift along long lines); bubble widths use the
    /// untracked width.
    static let bodyKern: CGFloat = -0.0028
    static let bubblePadX: CGFloat = 12
    static let bubblePadY: CGFloat = 7
    static let bubbleRadius: CGFloat = 15
    /// Baseline of the first text line below the bubble top.
    static let textBaseline: CGFloat = 20
    static let leftEdge: CGFloat = 20
    static let rightEdge: CGFloat = 608
    static let windowWidth: CGFloat = 628
    static let headerHeight: CGFloat = 80
    static let windowCornerRadius: CGFloat = 16
    /// Window height the outgoing gradient spans.
    static let gradientHeight: CGFloat = 1041
    static let centerX: CGFloat = 313.9
    static let receiptRight: CGFloat = 592.2
    static let labelLeft: CGFloat = 32
    /// Widest text line a bubble allows (wrapped lines keep their trailing space).
    static let maxTextWidth: CGFloat = 358.4
    static let maxLinkWidth: CGFloat = 350
    static let mediaWidth: CGFloat = 240

    /// Inactive-window palette (measured on macOS 26 Messages in an inactive
    /// window, 2x screenshot): background 30, incoming bubbles and badges 59,
    /// outgoing blue lighter (red 0.5 x + 61, green 0.67 x + 57, blue 248),
    /// connectors 66. Set on the main thread; a change bumps `paletteGeneration`.
    static var inactive = false { didSet { if inactive != oldValue { paletteGeneration += 1 } } }
    /// Light system appearance (the host sets it from its effective appearance).
    /// Link cards follow it: Messages' light card is the light incoming grey
    /// (#E9E9EB) with dark text. A change bumps `paletteGeneration`.
    static var lightAppearance = false { didSet { if lightAppearance != oldValue { paletteGeneration += 1 } } }
    /// Bumped by a palette or a scale change: cached bitmaps are stale.
    static fileprivate(set) var paletteGeneration = 0

    /// Palette, measured with `screencapture -l` on macOS 27 Messages
    /// (cmux-lawrence-2, 2026-10-05): key and non-key windows are identical
    /// to the level (0 pixels differ), so there is one palette. The values are
    /// Display P3 (the capture's profile), so the colours are made in Display
    /// P3: tagged sRGB they were converted on screen and the outgoing blue
    /// showed as (97, 149, 242) against Messages' (84, 152, 248). The earlier
    /// key-window palette (background 25, blue 0-43/132-141/253) came from
    /// the HEVC window recording, whose colour pipeline shifts both.
    static func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(displayP3Red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    /// cmux: the app theme's colours (the cmux-next Ghostty theme and the
    /// user's accent), set by the Home host; a change bumps
    /// `paletteGeneration`. nil keeps the measured Messages palette below
    /// (fixtures, the differential harness).
    static var theme: FixtureTheme? { didSet { if theme != oldValue { paletteGeneration += 1 } } }
    private static func themed(_ pick: (FixtureTheme.Colors) -> UIColor) -> UIColor? {
        theme.map { pick(inactive ? $0.inactive : $0.active) }
    }
    static var background: UIColor { themed(\.background) ?? UIColor(white: 30 / 255, alpha: 1) }
    static var incoming: UIColor { themed(\.incoming) ?? (elevated ? p3(76, 76, 78) : p3(59, 59, 61)) }
    /// Rows of an open thread or reply view are drawn lighter (macOS 27, measured 76, 76, 78;
    /// lossless thread-open-esc reference). Set only around those rows' drawing (main thread).
    static var elevated = false
    // cmux: a theme without an accent keeps the measured blue and its gradient.
    private static var themedAccent: Bool { theme.map { !$0.measuredAccent } ?? false }
    static var outgoing: UIColor { (themedAccent ? themed(\.outgoing) : nil) ?? UIColor(red: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1) }
    /// The text caret (and field tint): screencapture -l of a focused Messages field,
    /// 2 px wide at 2x, Display P3 (63, 143, 247). cmux: the theme's on a light theme.
    static var caret: UIColor { themed(\.caret) ?? p3(63, 143, 247) }
    static var connector: UIColor { themed(\.connector) ?? UIColor(white: 66 / 255, alpha: 1) }
    static var badge: UIColor { themed(\.badge) ?? p3(59, 59, 61) }
    /// Outgoing bubbles shade with their position in the window (measured:
    /// lighter near the top, deeper blue near the compose field).
    /// (window y in 2x px, red, green), Display P3.
    static let captionSize: CGFloat = 10
    static var gradientBlue: CGFloat { 247 }
    /// Fitted to the screencapture -l stills (Messages 628x1041 pt window,
    /// 200 samples, rms 0.5 levels; blue 247-248).
    static let gradientStops: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 90, 153.9), (300, 84.6, 152.3), (600, 79.9, 150.2), (900, 75.3, 148.5), (1200, 72.4, 147.3),
        (1500, 68.8, 145.8), (1800, 65.2, 144.1), (2082, 62.8, 142)]
    /// A gradient colour (red, green from the stops) in Display P3.
    static func gradientColor(_ r: CGFloat, _ g: CGFloat) -> UIColor { p3(r, g, gradientBlue) }
    private static let measuredGradient: CGGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
        colors: gradientStops.map { gradientColor($0.1, $0.2).cgColor } as CFArray,
        locations: gradientStops.map { $0.0 / 2082 })!
    /// cmux: the themed outgoing gradient as (2x px window y, colour) stops;
    /// nil keeps the measured stops (`gradientStops`, `gradientBlue`).
    static var themedGradient: [(CGFloat, UIColor)]? { themedAccent ? theme.map { (inactive ? $0.inactive : $0.active).gradientStops } : nil }
    static func color(in s: [(CGFloat, UIColor)], atPx px: CGFloat) -> UIColor {
        guard s.count > 1 else { return s.first?.1 ?? outgoing }
        var i = 1
        while i < s.count - 1, s[i].0 < px { i += 1 }
        let a = s[i - 1], b = s[i]
        let f = max(0, min(1, (px - a.0) / max(1, b.0 - a.0)))
        // cmux: a colour that cannot convert (pattern, catalog) falls back to the measured blue, never
        // the unconverted colour (its redComponent throws).
        let ca = a.1.usingColorSpace(.displayP3) ?? Fixture.p3(2, 132, 254), cb = b.1.usingColorSpace(.displayP3) ?? Fixture.p3(2, 132, 254)
        return UIColor(displayP3Red: ca.redComponent + (cb.redComponent - ca.redComponent) * f,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * f,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * f, alpha: 1)
    }
    static var outgoingGradient: CGGradient {
        if let t = theme, themedAccent { return (inactive ? t.inactive : t.active).outgoingGradient }
        return measuredGradient
    }
    /// Text colours measured with screencapture -l (macOS 27, 2026-10-05).
    static var incomingText: UIColor { themed(\.incomingText) ?? UIColor(white: (elevated ? 242 : 225) / 255, alpha: 1) }
    static var outgoingText: UIColor { (themedAccent ? themed(\.outgoingText) : nil) ?? UIColor.white }
    static var secondaryText: UIColor { themed(\.secondaryText) ?? UIColor(white: 154 / 255, alpha: 1) }
    // cmux: the field and typing colours MessagesLab draws as fixed dark
    // values, from the theme on a light one; nil keeps the measured values.
    static var typingDot: UIColor { themed(\.typingDot) ?? p3(91, 91, 94) }
    static var typingDotHighlight: UIColor { themed(\.typingDotHighlight) ?? p3(133, 133, 135) }
    static var placeholder: UIColor { themed(\.placeholder) ?? UIColor(white: 123 / 255, alpha: 1) }
    static var waveform: UIColor { themed(\.waveform) ?? UIColor(white: 144 / 255, alpha: 1) }
    static var chipFill: UIColor { themed(\.chipFill) ?? UIColor(white: 1, alpha: 0.12) }
    /// The field glass and its buttons render light glass on a light theme.
    static var isLight: Bool { theme.map { (inactive ? $0.inactive : $0.active).isLight } ?? false }
}

