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
        let outgoingGradient: CGGradient

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
                                          locations: stops.map(\.location))!
        }

        static func == (a: Colors, b: Colors) -> Bool { a.palette == b.palette }
    }

    let active: Colors
    let inactive: Colors

    init(active: HomePalette, inactive: HomePalette) {
        self.active = Colors(active)
        self.inactive = Colors(inactive)
    }
}
