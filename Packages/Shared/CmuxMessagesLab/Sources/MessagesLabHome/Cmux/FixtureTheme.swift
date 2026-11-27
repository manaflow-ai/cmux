import AppKit
import CmuxHomeRender

/// The cmux theme as MessagesLab's `Fixture` colours (`Fixture.theme`). The
/// host builds `HomePalette`s from the cmux-next theme (the Ghostty theme and
<<<<<<< HEAD
/// the user's accent, `HomeThemePalette`), the key window's palette for every
/// window and state (as Messages on macOS 27, a non-key window draws the same
/// bubbles; the per-view inactive state greys only the typing indicator,
/// MessagesLab 806ef0c); this maps its roles onto the Fixture names the
/// vendored drawing reads.
/// Geometry, fonts and motion stay MessagesLab's.
struct FixtureTheme: Equatable, Sendable {
    struct Colors: Equatable, Sendable {
=======
/// the user's accent, `HomeThemePalette`) for the key and the non-key window;
/// this maps their roles onto the Fixture names the vendored drawing reads.
/// Geometry, fonts and motion stay MessagesLab's.
struct FixtureTheme: Equatable {
    struct Colors: Equatable {
>>>>>>> origin/main
        let palette: HomePalette
        let background: NSColor
        let incoming: NSColor
        let outgoing: NSColor
        let connector: NSColor
        let badge: NSColor
        let incomingText: NSColor
<<<<<<< HEAD
        /// The composer's own text and symbols (palette `composeText`: the theme's, whatever a chat's bubbles chose).
        let composeText: NSColor
=======
>>>>>>> origin/main
        let outgoingText: NSColor
        let secondaryText: NSColor
        /// (2x px window y, colour), over the gradient's 1041 pt.
        let gradientStops: [(CGFloat, NSColor)]
<<<<<<< HEAD
        /// The sent bubble's gradient colours (sRGB CGColors, made once here) and their locations (0...1): the
        /// palette's stops, else its caret alone.
        private let outgoingColors: [CGColor]
        private let outgoingLocations: [CGFloat]
        /// The sent bubble's gradient, made from the ready ``outgoingColors`` when a bubble draws (row and tile renders,
        /// which cache their bitmaps): a CGGradient is not Sendable (a CGColor is), so the theme keeps the colours, not
        /// the gradient, and stays a checked Sendable value. nil when Core Graphics refuses the stops (bubbles then
        /// draw no gradient).
        var outgoingGradient: CGGradient? {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: outgoingColors as CFArray,
                       locations: outgoingLocations)
        }
=======
        /// nil when Core Graphics refuses the stops (bubbles then draw no gradient).
        let outgoingGradient: CGGradient?
>>>>>>> origin/main
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
<<<<<<< HEAD
        /// The field's hairline edge on a light theme (palette `composeStroke`, 3:1 on the page).
        let fieldEdge: NSColor
        /// The field's fill over a see-through window (palette `composeFillOverGlass`); nil keeps its clear glass.
        let fieldFill: NSColor?

        /// `measured`: the iMessage style, whose dark caret is Messages' own; the theme's look keeps the theme's caret.
        init(_ p: HomePalette, measured: Bool = true) {
=======

        /// - Parameter measuredBlue: sent bubbles take MessagesLab's measured dark-window blue and
        ///   gradient (`Fixture.gradientStops`, blue 247; `Fixture.outgoing`, rgb(2, 132, 254)) and
        ///   white text instead of the palette's accent. `FixtureTheme` sets it on a light theme with
        ///   a measured accent: there the vendored palette's own measured light blue (red +22,
        ///   green +31) is too pale for white text (about 2.2:1 at the top of the window).
        init(_ p: HomePalette, measuredBlue: Bool = false) {
>>>>>>> origin/main
            palette = p
            func c(_ h: HomeColor) -> NSColor { NSColor(srgbRed: h.red, green: h.green, blue: h.blue, alpha: h.alpha) }
            background = c(p.background)
            incoming = c(p.incomingBubble)
<<<<<<< HEAD
            // The sent bubble's solid colour: its gradient's first stop (the caret is a colour of its own).
            outgoing = c(p.outgoingGradient.first?.color ?? p.caret)
            connector = c(p.typingDot)
            badge = c(p.badge)
            incomingText = c(p.incomingText)
            composeText = c(p.composeText)
            outgoingText = c(p.outgoingText)
            secondaryText = c(p.secondaryText)
            let span = Fixture.gradientHeight * 2
            let stops = p.outgoingGradient.isEmpty ? [HomePalette.GradientStop(location: 0, color: p.caret)] : p.outgoingGradient
            gradientStops = stops.map { (span * $0.location, c($0.color)) }
            outgoingColors = stops.map { $0.color.cgColor }
            outgoingLocations = stops.map(\.location)
            let bg = p.background
            let light = 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue > 0.5
=======
            connector = c(p.typingDot)
            badge = c(p.badge)
            incomingText = c(p.incomingText)
            secondaryText = c(p.secondaryText)
            if measuredBlue {
                outgoing = NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1)
                outgoingText = .white
                let measured = Fixture.gradientStops.map { ($0.0, Fixture.p3($0.1, $0.2, 247)) }
                gradientStops = measured
                let span = Fixture.gradientHeight * 2
                outgoingGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
                                              colors: measured.map { $0.1.cgColor } as CFArray,
                                              locations: measured.map { $0.0 / span })
            } else {
                outgoing = c(p.caret)
                outgoingText = c(p.outgoingText)
                let span = Fixture.gradientHeight * 2
                let stops = p.outgoingGradient.isEmpty ? [HomePalette.GradientStop(location: 0, color: p.caret)] : p.outgoingGradient
                gradientStops = stops.map { (span * $0.location, c($0.color)) }
                outgoingGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                              colors: stops.map { $0.color.cgColor } as CFArray,
                                              locations: stops.map(\.location))
            }
            let light = Self.isLight(p.background)
>>>>>>> origin/main
            isLight = light
            // MessagesLab's measured dark values (Transcript, Compose), made in
            // Display P3 like its palette (Fixture.p3; the measurements are P3).
            typingDot = light ? c(p.typingDot) : Fixture.p3(91, 91, 94)
            typingDotHighlight = light ? c(p.typingDotHighlight) : Fixture.p3(133, 133, 135)
<<<<<<< HEAD
            // The placeholder is the palette's, 4.5:1 on the field in light and dark (user 2026-10-19: the
            // composer's placeholder looked dark). MessagesLab's measured dark ink (white 0.316 over the
            // field glass, Fixture.placeholderInk) is 2.6:1 on Messages' 59 field. The dark waveform keeps
            // MessagesLab's see-through ink (212 at 0.556): it is a graphic, not text.
            placeholder = c(p.placeholder)
            waveform = light ? c(p.placeholder) : NSColor(white: 212 / 255, alpha: 0.556)
            caret = light || !measured ? c(p.caret) : Fixture.p3(63, 143, 247)
            fieldEdge = c(p.composeStroke)
            fieldFill = p.composeFillOverGlass.map(c)
            chipFill = light ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.12)
        }

        static func == (a: Colors, b: Colors) -> Bool { a.palette == b.palette }
    }

    let active: Colors
    /// The theme names no accent: sent bubbles keep MessagesLab's measured
    /// blue and gradient (Fixture.outgoing, gradientStops) and white text.
    let measuredAccent: Bool

    init(active: HomePalette, measuredAccent: Bool = false) {
        self.active = Colors(active, measured: measuredAccent)
        self.measuredAccent = measuredAccent
=======
            // The dark placeholder and waveform are see-through inks over the field glass (MessagesLab
            // compose-parity, Fixture.placeholderInk / waveformInk: white 0.316, 212 at 0.556).
            placeholder = light ? c(p.placeholder) : NSColor(white: 1, alpha: 0.316)
            waveform = light ? c(p.placeholder) : NSColor(white: 212 / 255, alpha: 0.556)
            caret = light ? c(p.caret) : Fixture.p3(63, 143, 247)
            chipFill = light ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.12)
        }

        /// A light background: luminance above one half.
        static func isLight(_ bg: HomeColor) -> Bool { 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue > 0.5 }

        static func == (a: Colors, b: Colors) -> Bool { a.palette == b.palette && a.outgoing == b.outgoing }
    }

    let active: Colors
    let inactive: Colors
    /// The vendored palette draws the sent bubbles (Fixture.outgoing, gradientStops, white text):
    /// the theme names no accent and is dark.
    let measuredAccent: Bool

    /// - Parameter measuredAccent: the theme names no accent, so sent bubbles keep MessagesLab's
    ///   measured blue and gradient and white text. On a dark theme the vendored palette draws them;
    ///   on a light one `Colors` carries the same measured dark-window blue (`measuredBlue`), so the
    ///   sent bubble is iMessage blue with readable white text in light too, never the vendored
    ///   palette's paler light-appearance blue.
    init(active: HomePalette, inactive: HomePalette, measuredAccent: Bool = false) {
        let light = Colors.isLight(active.background)
        self.active = Colors(active, measuredBlue: measuredAccent && light)
        self.inactive = Colors(inactive, measuredBlue: measuredAccent && light)
        self.measuredAccent = measuredAccent && !light
>>>>>>> origin/main
    }
}
