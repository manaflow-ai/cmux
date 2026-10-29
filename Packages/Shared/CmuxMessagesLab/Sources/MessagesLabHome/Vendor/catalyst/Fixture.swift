#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Measured style metrics. Geometry is in points of a 628x1041 pt window.
enum Fixture {
    static let windowSize = CGSize(width: 628, height: 1041)
    /// The scale bitmaps and device pixel snaps use now: inside `withRenderScale` (a window view's own work, its
    /// cells, its bitmap jobs) the view's scale (MessagesWindowView.renderScale), else `fallbackRenderScale`.
    /// Setting it sets the fallback. Test renders (capture, live grab) set 2, the reference's scale.
    static var renderScale: CGFloat {
        get { RenderScaleScope.current ?? fallbackRenderScale } // cmux: no task local on main outside a task
        set { fallbackRenderScale = newValue }
    }
    /// The process value for code with no view: set from the first window's screen at launch and by every
    /// `MessagesWindowView.setRenderScale` (the last display change). A change does not bump `paletteGeneration`:
    /// every scale-dependent cache is keyed by its scale (row bitmaps, tiles, badges, masks, decoded assets), and a
    /// cell redraws when its own scale changes, so one window's scale change does not redraw another window's rows.
    static var fallbackRenderScale: CGFloat = 2

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

    // The inactive-window state is not here: it is each window view's own (MessagesWindowView.inactive, set by its
    // setInactive from its own window's key state; cx-3cb inactive-per-view). Two windows draw two states at the same
    // time, as Messages: a non-key window draws inactive while another one is key. Its readers take it as a value
    // (`typingColors(inactive:)`, ChromeView.inactive, RowCell.inactive). macOS 27's bubbles, background and
    // connectors are the same in both states (see the palette below), so no cached bitmap depends on it.
    /// Light system appearance (the host sets it from its effective appearance).
    /// Link cards follow it: Messages' light card is the light incoming grey
    /// (#E9E9EB) with dark text. A change bumps `paletteGeneration`.
    static var lightAppearance = false { didSet { if lightAppearance != oldValue { paletteGeneration += 1 } } }
    /// Bumped by an appearance or a colour space change: cached bitmaps are stale (not by a window's key state).
    static fileprivate(set) var paletteGeneration = 0
    /// The bitmaps' colour space changed (a window moved to a display of another colour space): every cache keyed
    /// on the palette generation draws again (MessagesWindowView.displayColorSpaceChanged).
    static func colorSpaceChanged() { paletteGeneration += 1 }

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
    /// (fixtures, the differential harness), light or dark (`lightAppearance`).
    static var theme: FixtureTheme? { didSet { if theme != oldValue { paletteGeneration += 1 } } }
    private static func themed(_ pick: (FixtureTheme.Colors) -> UIColor) -> UIColor? {
        theme.map { pick($0.active) }
    }
    /// Light appearance (`lightAppearance`), measured on light and dark captures of the same
    /// Messages window (screencapture -l, Display P3, cmux-lawrence-2 macOS 27, 2026-10-09):
    /// background 255, incoming 233/233/235, incoming text 36, secondary text 134, connector 235.
    /// The thread view's elevated rows and the tapback badge in light are UNVERIFIED (not in the take).
    static var background: UIColor { themed(\.background) ?? (lightAppearance ? UIColor(white: 1, alpha: 1) : UIColor(white: 30 / 255, alpha: 1)) }
    /// The compose field's placeholder and audio waveform are see-through in Messages: the same ink over the
    /// key field (59, light 249) and the inactive one (50, light 240) is a constant step from it (lossless
    /// deactivate-activate and appearance-light takes, macOS 27, cx-3cb compose-parity): placeholder +63 in dark
    /// (122 and 113 at full coverage), -66 in light (183 and 174); waveform 144 and 140 in dark, 152 and 145 in
    /// light. White at 0.316 (dark) and black at 0.27 (light) over the field give them within 1.5 levels in both
    /// states; the waveform is 212 at 0.556 (dark, exact) and black at 0.39 (light). Opaque 123 and 144 before:
    /// 10 levels too light on the inactive dark field, 60 levels too dark in light.
    static var placeholderInk: UIColor { lightAppearance ? UIColor(white: 0, alpha: 0.27) : UIColor(white: 1, alpha: 0.316) }
    static var waveformInk: UIColor { lightAppearance ? UIColor(white: 0, alpha: 0.39) : UIColor(white: 212 / 255, alpha: 0.556) }
    static var incoming: UIColor { themed(\.incoming) ?? (lightAppearance ? p3(233, 233, 235) : elevated ? p3(76, 76, 78) : p3(59, 59, 61)) }
    /// The typing indicator (bubble, tail discs, dots) is not the incoming grey: in Messages' key window it is
    /// one level darker in red and green (bubble and discs 58, 58, 61; dots dim 91, 91, 94, lit 133, 133, 135:
    /// the 12 settled lossless stills typing-dots-02..13 and send-typed-take1 +5.5 s), in its inactive window it
    /// is not (59, 59, 61; dots dim 92, 92, 94, lit 134, 134, 135: typing-unfocused-take1, its 61 frames at rest),
    /// while the incoming bubbles are 59, 59, 61 in both (tools/evidence/ANIMATIONS.md section 6, cx-3cb
    /// typing-colour). Light appearance and the thread view's rows: no reference; the incoming grey and the dark dots.
    /// `inactive`: the drawing view's own state (MessagesWindowView.inactive, through RowCell.inactive).
    static func typingColors(inactive: Bool) -> (fill: UIColor, dotDim: UIColor, dotLit: UIColor) {
        let dim = inactive && !lightAppearance && !elevated
        // cmux: on a theme, the theme's incoming grey; a dark one is one level darker in red and green in the key
        // window, as Messages' (a light theme has no reference: the incoming grey and the theme's dots).
        if theme != nil {
            let fill = isLight || elevated || inactive ? incoming : oneLevelDarker(incoming)
            if isLight { return (fill, typingDot, typingDotHighlight) }
            return (fill, dim ? p3(92, 92, 94) : p3(91, 91, 94), dim ? p3(134, 134, 135) : p3(133, 133, 135))
        }
        return (lightAppearance || elevated ? incoming : inactive ? p3(59, 59, 61) : p3(58, 58, 61),
                dim ? p3(92, 92, 94) : p3(91, 91, 94), dim ? p3(134, 134, 135) : p3(133, 133, 135))
    }
    /// cmux: 1/255 less red and green (Display P3), the key window's typing fill on a dark theme.
    private static func oneLevelDarker(_ c: UIColor) -> UIColor {
        guard let p = c.usingColorSpace(.displayP3) else { return c }
        return UIColor(displayP3Red: max(0, p.redComponent - 1 / 255), green: max(0, p.greenComponent - 1 / 255),
                       blue: p.blueComponent, alpha: p.alphaComponent)
    }
    /// Rows of an open thread or reply view are drawn lighter (macOS 27, measured 76, 76, 78;
    /// lossless thread-open-esc reference). Set only around those rows' drawing (main thread).
    static var elevated = false
    // cmux: a theme without an accent keeps the measured blue and its gradient.
    private static var themedAccent: Bool { theme.map { !$0.measuredAccent } ?? false }
    static var outgoing: UIColor { (themedAccent ? themed(\.outgoing) : nil) ?? UIColor(red: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1) }
    /// The text caret (and field tint): screencapture -l of a focused Messages field,
    /// 2 px wide at 2x, Display P3 (63, 143, 247). cmux: the theme's on a light theme.
    static var caret: UIColor { themed(\.caret) ?? p3(63, 143, 247) }
    /// The capture caret after a send (cx-3cb parity26; Messages' macOS 26 original recording 4.65-5.30 s and
    /// macOS 27 send-typed-take1, lossless): it stays on the field's first line while the field collapses (the
    /// compose view moves it with the placeholder), starts in the accent colour and turns grey 0.04-0.22 s after
    /// the send (ease-out; macOS 26 blue channel 255 -> 112 by 0.22 s), is off 0.59-0.65 s and is back in the
    /// accent colour (then the 1 s blink) at 0.65 s.
    enum SendCaret {
        static let grayFrom = 0.04, grayTo = 0.22, offFrom = 0.59, end = 0.65
        static let gray = (r: 128.0, g: 128.0, b: 128.0), accent = (r: 63.0, g: 143.0, b: 247.0)
        /// Opacity and colour `s` seconds after the send; nil from `end` on (the normal caret).
        static func state(_ s: Double) -> (alpha: Double, color: UIColor)? {
            guard s >= 0, s < end else { return nil }
            let u = min(1, max(0, (s - grayFrom) / (grayTo - grayFrom)))
            let m = 1 - (1 - u) * (1 - u)
            let c = Fixture.p3(CGFloat(accent.r + (gray.r - accent.r) * m), CGFloat(accent.g + (gray.g - accent.g) * m),
                               CGFloat(accent.b + (gray.b - accent.b) * m))
            return (s < 0.02 || s >= offFrom ? 0 : 1, c)
        }
    }
    static var connector: UIColor { themed(\.connector) ?? (lightAppearance ? UIColor(white: 235 / 255, alpha: 1) : UIColor(white: 66 / 255, alpha: 1)) }
    static var badge: UIColor { themed(\.badge) ?? (lightAppearance ? p3(233, 233, 235) : p3(59, 59, 61)) }
    /// Outgoing bubbles shade with their position in the window (measured:
    /// lighter near the top, deeper blue near the compose field).
    /// (window y in 2x px, red, green), Display P3.
    static let captionSize: CGFloat = 10
    static var gradientBlue: CGFloat { lightAppearance ? 246 : 247 }
    /// Fitted to the screencapture -l stills (Messages 628x1041 pt window,
    /// 200 samples, rms 0.5 levels; blue 247-248).
    static let gradientStops: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 90, 153.9), (300, 84.6, 152.3), (600, 79.9, 150.2), (900, 75.3, 148.5), (1200, 72.4, 147.3),
        (1500, 68.8, 145.8), (1800, 65.2, 144.1), (2082, 62.8, 142)]
    /// A gradient colour (red, green from the stops) in Display P3.
    /// Light appearance: Messages' light outgoing blue is lighter by red +22, green +31 (blue 246),
    /// measured on light and dark captures of one Messages window (2026-10-09, cmux-lawrence-2,
    /// bubbles in the top 700 px only; lower in the window UNVERIFIED).
    static func gradientColor(_ r: CGFloat, _ g: CGFloat) -> UIColor { lightAppearance ? lightGradientColor(r, g) : p3(r, g, 247) }
    static func lightGradientColor(_ r: CGFloat, _ g: CGFloat) -> UIColor { p3(r + 22, g + 31, 246) }
    private static func gradient(_ color: (CGFloat, CGFloat) -> UIColor) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
                   colors: gradientStops.map { color($0.1, $0.2).cgColor } as CFArray,
                   locations: gradientStops.map { $0.0 / 2082 })
    }
    // optional, no force unwrap ; a nil gradient draws nothing.
    private static let darkGradient = gradient { p3($0, $1, 247) }
    private static let lightGradient = gradient(lightGradientColor)
    private static var measuredGradient: CGGradient? { (lightAppearance ? lightGradient : nil) ?? darkGradient }
    /// cmux: the themed outgoing gradient as (2x px window y, colour) stops;
    /// nil keeps the measured stops (`gradientStops`, `gradientBlue`).
    static var themedGradient: [(CGFloat, UIColor)]? { themedAccent ? theme.map { $0.active.gradientStops } : nil }
    static func color(in s: [(CGFloat, UIColor)], atPx px: CGFloat) -> UIColor {
        guard s.count > 1 else { return s.first?.1 ?? outgoing }
        // cmux: the first inner stop at or past px, else the last; checked reads.
        let upper = s.dropFirst().dropLast().firstIndex(where: { $0.0 >= px }) ?? s.count - 1
        guard let a = s[checked: upper - 1], let b = s[checked: upper] else { return s.first?.1 ?? outgoing }
        let f = max(0, min(1, (px - a.0) / max(1, b.0 - a.0)))
        // cmux: a colour that cannot convert (pattern, catalog) falls back to the measured blue, never
        // the unconverted colour (its redComponent throws).
        let ca = a.1.usingColorSpace(.displayP3) ?? Fixture.p3(2, 132, 254), cb = b.1.usingColorSpace(.displayP3) ?? Fixture.p3(2, 132, 254)
        return UIColor(displayP3Red: ca.redComponent + (cb.redComponent - ca.redComponent) * f,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * f,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * f, alpha: 1)
    }
    /// cmux: links in the Chief's text, the "Edited" label and "N Replies" are Messages' blues; the theme style
    /// (a theme that is not the measured accent) draws them in the theme's caret colour (its accent, or its text).
    private static var themedLink: UIColor? { themedAccent ? themed(\.caret) : nil }
    static var incomingLink: UIColor { themedLink ?? UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1) }
    static var labelLink: UIColor { themedLink ?? UIColor(red: 0.2, green: 0.55, blue: 1, alpha: 1) }
    /// cmux: the outline and text of my quoted root above a reply (macOS 27 Messages, dark, the user's 2x reference of
    /// 2026-10-28: outline sRGB 56/96/139, text 60/124/212 on the dark background). Light mode and a themed accent mix the
    /// outgoing blue into the background instead: UNVERIFIED against a light Messages reference.
    static var quoteOutline: UIColor {
        if !themedAccent, !lightAppearance { return UIColor(srgbRed: 56 / 255, green: 96 / 255, blue: 139 / 255, alpha: 1) }
        return mix(outgoing, into: background, 0.45)
    }
    static var quoteText: UIColor {
        if !themedAccent, !lightAppearance { return UIColor(srgbRed: 60 / 255, green: 124 / 255, blue: 212 / 255, alpha: 1) }
        return mix(outgoing, into: background, 0.85)
    }
    /// `c` at `amount` over `base`, in sRGB.
    private static func mix(_ c: UIColor, into base: UIColor, _ amount: CGFloat) -> UIColor {
        guard let a = c.usingColorSpace(.sRGB), let b = base.usingColorSpace(.sRGB) else { return c }
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { y + (x - y) * amount }
        return UIColor(srgbRed: m(a.redComponent, b.redComponent), green: m(a.greenComponent, b.greenComponent),
                       blue: m(a.blueComponent, b.blueComponent), alpha: 1)
    }
    static var repliesTint: UIColor { themedLink ?? PreviewStyle.repliesBlue }
    static var outgoingGradient: CGGradient? {
        if let t = theme, themedAccent { return t.active.outgoingGradient }
        return measuredGradient
    }
    /// Text colours measured with screencapture -l (macOS 27, 2026-10-05).
    static var incomingText: UIColor { themed(\.incomingText) ?? (lightAppearance ? UIColor(white: 36 / 255, alpha: 1) : UIColor(white: (elevated ? 242 : 225) / 255, alpha: 1)) }
    static var outgoingText: UIColor { (themedAccent ? themed(\.outgoingText) : nil) ?? UIColor.white }
    static var secondaryText: UIColor { themed(\.secondaryText) ?? (lightAppearance ? UIColor(white: 134 / 255, alpha: 1) : UIColor(white: 154 / 255, alpha: 1)) }
    // cmux: the field and typing colours MessagesLab draws as fixed dark
    // values, from the theme on a light one; nil keeps the measured values.
    static var typingDot: UIColor { themed(\.typingDot) ?? p3(91, 91, 94) }
    static var typingDotHighlight: UIColor { themed(\.typingDotHighlight) ?? p3(133, 133, 135) }
    static var placeholder: UIColor { themed(\.placeholder) ?? placeholderInk }
    static var waveform: UIColor { themed(\.waveform) ?? waveformInk }
    static var chipFill: UIColor { themed(\.chipFill) ?? UIColor(white: 1, alpha: 0.12) }
    /// The field glass and its buttons render light glass on a light theme.
    static var isLight: Bool { theme.map { $0.active.isLight } ?? false }
}

