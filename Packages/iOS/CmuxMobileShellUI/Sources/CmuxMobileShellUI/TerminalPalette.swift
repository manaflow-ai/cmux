import SwiftUI

/// The fixed Monokai-derived color palette for the mobile terminal surface.
///
/// These match the colors libghostty renders the terminal background/foreground
/// with, so the SwiftUI chrome around the surface (toolbars, letterbox fill)
/// blends with the live terminal instead of flashing a system color.
struct TerminalPalette {
    private init() {}

    /// Terminal background (`#272822`).
    static let background = Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0)
    /// Terminal foreground (`#f8f8f2`).
    static let foreground = Color(red: 0xf8 / 255.0, green: 0xf8 / 255.0, blue: 0xf2 / 255.0)
    /// Dimmed terminal foreground (`#c8c8c0`).
    static let dimForeground = Color(red: 0xc8 / 255.0, green: 0xc8 / 255.0, blue: 0xc0 / 255.0)
}
