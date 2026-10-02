public import AppKit
public import CmuxTheme

extension ThemeRGB {
    /// This color in sRGB, for AppKit.
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// This color in sRGB, for Core Animation layers.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
