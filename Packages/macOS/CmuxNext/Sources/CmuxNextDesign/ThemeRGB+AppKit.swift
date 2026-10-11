public import AppKit
public import CmuxTheme

// The struct was nonisolated in CmuxNextDesign; this module defaults to the
// main actor, so the conversions opt out to stay usable from layers and
// background code.
extension ThemeRGB {
    /// This color in sRGB, for AppKit.
    nonisolated public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// This color in sRGB, for Core Animation layers.
    nonisolated public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
