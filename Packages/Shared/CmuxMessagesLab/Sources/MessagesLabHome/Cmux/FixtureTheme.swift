import AppKit
import CmuxHomeRender

/// The cmux theme as MessagesLab's `Fixture` colours (`Fixture.theme`). The
/// host builds `HomePalette`s from the cmux-next theme (the Ghostty theme and
/// the user's accent, `HomeThemePalette`) for the key and the non-key window;
/// this maps their roles onto the Fixture names the vendored drawing reads.
/// Geometry, fonts and motion stay MessagesLab's.
struct FixtureTheme: Equatable {
    struct Colors: Equatable {
        let palette: HomePalette
        let background: NSColor
        let incoming: NSColor
        let outgoing: NSColor
        let connector: NSColor
        let badge: NSColor
        let incomingText: NSColor
        let outgoingText: NSColor
        let secondaryText: NSColor
        /// (2x px window y, colour), over the gradient's 1041 pt.
        let gradientStops: [(CGFloat, NSColor)]
        /// nil when Core Graphics refuses the stops (bubbles then draw no gradient).
        let outgoingGradient: CGGradient?
        /// A light theme (background luminance above one half). MessagesLab
        /// measured a dark window only: on a dark theme the field and typing
        /// colours below keep its measured values; a light theme takes the
        /// palette's.
        let isLight: Bool
        let typingDot: NSColor
        let typingDotHighlight: NSColor
        let placeholder: NSColor
        let waveform: NSColor
        let caret: NSColor
        let chipFill: NSColor

        init(_ p: HomePalette) {
            palette = p
            func c(_ h: HomeColor) -> NSColor { NSColor(srgbRed: h.red, green: h.green, blue: h.blue, alpha: h.alpha) }
            background = c(p.background)
            incoming = c(p.incomingBubble)
            outgoing = c(p.caret)
            connector = c(p.typingDot)
            badge = c(p.badge)
            incomingText = c(p.incomingText)
            outgoingText = c(p.outgoingText)
            secondaryText = c(p.secondaryText)
            let span = Fixture.gradientHeight * 2
            let stops = p.outgoingGradient.isEmpty ? [HomePalette.GradientStop(location: 0, color: p.caret)] : p.outgoingGradient
            gradientStops = stops.map { (span * $0.location, c($0.color)) }
            outgoingGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: stops.map { $0.color.cgColor } as CFArray,
                                          locations: stops.map(\.location))
            let bg = p.background
            let light = 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue > 0.5
            isLight = light
            // MessagesLab's measured dark values (Transcript, Compose), made in
            // Display P3 like its palette (Fixture.p3; the measurements are P3).
            typingDot = light ? c(p.typingDot) : Fixture.p3(91, 91, 94)
            typingDotHighlight = light ? c(p.typingDotHighlight) : Fixture.p3(133, 133, 135)
            placeholder = light ? c(p.placeholder) : NSColor(white: 123 / 255, alpha: 1)
            waveform = light ? c(p.placeholder) : NSColor(white: 144 / 255, alpha: 1)
            caret = light ? c(p.caret) : Fixture.p3(63, 143, 247)
            chipFill = light ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.12)
        }

        static func == (a: Colors, b: Colors) -> Bool { a.palette == b.palette }
    }

    let active: Colors
    let inactive: Colors
    /// The theme names no accent: sent bubbles keep MessagesLab's measured
    /// blue and gradient (Fixture.outgoing, gradientStops) and white text.
    let measuredAccent: Bool

    init(active: HomePalette, inactive: HomePalette, measuredAccent: Bool = false) {
        self.active = Colors(active)
        self.inactive = Colors(inactive)
        self.measuredAccent = measuredAccent
    }
}
