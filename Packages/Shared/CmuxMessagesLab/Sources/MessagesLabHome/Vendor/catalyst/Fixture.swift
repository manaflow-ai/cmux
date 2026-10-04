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
    /// Bumped by a palette or a scale change: cached bitmaps are stale.
    static fileprivate(set) var paletteGeneration = 0

    /// cmux: the app theme's colours (the cmux-next Ghostty theme and the
    /// user's accent), set by the Home host; a change bumps
    /// `paletteGeneration`. nil keeps the measured Messages palette below
    /// (fixtures, the differential harness).
    static var theme: FixtureTheme? { didSet { if theme != oldValue { paletteGeneration += 1 } } }
    private static func themed(_ pick: (FixtureTheme.Colors) -> UIColor) -> UIColor? {
        theme.map { pick(inactive ? $0.inactive : $0.active) }
    }

    static var background: UIColor { themed(\.background) ?? UIColor(white: (inactive ? 30 : 25) / 255, alpha: 1) }
    static var incoming: UIColor { themed(\.incoming) ?? UIColor(white: (inactive ? 59 : 49) / 255, alpha: 1) }
    static var outgoing: UIColor { themed(\.outgoing) ?? UIColor(red: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1) }
    static var connector: UIColor { themed(\.connector) ?? UIColor(white: (inactive ? 66 : 80) / 255, alpha: 1) }
    static var badge: UIColor { themed(\.badge) ?? (inactive ? UIColor(white: 59 / 255, alpha: 1) : UIColor(red: 59 / 255, green: 59 / 255, blue: 61 / 255, alpha: 1)) }
    /// Outgoing bubbles shade with their position in the window (measured:
    /// lighter near the top, deeper blue near the compose field).
    /// (window y in 2x px, red, green), measured from bubble centers.
    static let captionSize: CGFloat = 10
    static var gradientBlue: CGFloat { inactive ? 248 : 253 }
    static let activeStops: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 43, 141), (400, 42, 140.5), (540, 41, 140), (800, 36.5, 139), (1200, 28.5, 136.6), (1490, 20, 135),
        (1600, 15.3, 134.3), (1800, 6.9, 133.1), (1900, 2, 132.5), (1960, 0, 132), (2082, 0, 132)]
    static var gradientStops: [(CGFloat, CGFloat, CGFloat)] {
        inactive ? activeStops.map { ($0.0, 0.5 * $0.1 + 61, 0.67 * $0.2 + 57) } : activeStops
    }
    private static func gradient(_ stops: [(CGFloat, CGFloat, CGFloat)], blue: CGFloat) -> CGGradient {
        let colors = stops.map { UIColor(red: $0.1 / 255, green: $0.2 / 255, blue: blue / 255, alpha: 1).cgColor }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                          locations: stops.map { $0.0 / 2082 })!
    }
    private static let activeGradient = gradient(activeStops, blue: 253)
    private static let inactiveGradient = gradient(activeStops.map { ($0.0, 0.5 * $0.1 + 61, 0.67 * $0.2 + 57) }, blue: 248)
    /// cmux: the themed outgoing gradient as (2x px window y, colour) stops;
    /// nil keeps the measured stops (`gradientStops`, `gradientBlue`).
    static var themedGradient: [(CGFloat, UIColor)]? { theme.map { (inactive ? $0.inactive : $0.active).gradientStops } }
    static func color(in s: [(CGFloat, UIColor)], atPx px: CGFloat) -> UIColor {
        guard s.count > 1 else { return s.first?.1 ?? outgoing }
        var i = 1
        while i < s.count - 1, s[i].0 < px { i += 1 }
        let a = s[i - 1], b = s[i]
        let f = max(0, min(1, (px - a.0) / max(1, b.0 - a.0)))
        let ca = a.1.usingColorSpace(.sRGB) ?? a.1, cb = b.1.usingColorSpace(.sRGB) ?? b.1
        return UIColor(red: ca.redComponent + (cb.redComponent - ca.redComponent) * f,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * f,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * f, alpha: 1)
    }
    static var outgoingGradient: CGGradient {
        if let t = theme { return (inactive ? t.inactive : t.active).outgoingGradient }
        return inactive ? inactiveGradient : activeGradient
    }
    static var incomingText: UIColor { themed(\.incomingText) ?? UIColor(white: 220 / 255, alpha: 1) }
    static var outgoingText: UIColor { themed(\.outgoingText) ?? UIColor.white }
    static var secondaryText: UIColor { themed(\.secondaryText) ?? UIColor(white: 148 / 255, alpha: 1) }
    // cmux: the field and typing colours MessagesLab draws as fixed dark
    // values, from the theme on a light one; nil keeps the measured values.
    static var typingDot: UIColor { themed(\.typingDot) ?? UIColor(white: 82 / 255, alpha: 1) }
    static var typingDotHighlight: UIColor { themed(\.typingDotHighlight) ?? UIColor(white: 123 / 255, alpha: 1) }
    static var placeholder: UIColor { themed(\.placeholder) ?? UIColor(white: 0.43, alpha: 1) }
    static var waveform: UIColor { themed(\.waveform) ?? UIColor(white: 0.45, alpha: 1) }
    static var caret: UIColor { themed(\.caret) ?? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1) }
    static var chipFill: UIColor { themed(\.chipFill) ?? UIColor(white: 1, alpha: 0.12) }
    /// The field glass and its buttons render light glass on a light theme.
    static var isLight: Bool { theme.map { (inactive ? $0.inactive : $0.active).isLight } ?? false }
}

