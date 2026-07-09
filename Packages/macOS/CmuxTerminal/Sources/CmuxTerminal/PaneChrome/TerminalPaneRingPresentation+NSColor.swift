import AppKit
import CmuxTerminalCore

extension TerminalPaneRingPresentation {
    /// The resolved stroke/glow color as an `NSColor`.
    ///
    /// The app target lowers its attention palette into the `Sendable` sRGB
    /// components carried by this value; the overlay container materializes the
    /// color here without ever importing the app-target palette type.
    var strokeColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
