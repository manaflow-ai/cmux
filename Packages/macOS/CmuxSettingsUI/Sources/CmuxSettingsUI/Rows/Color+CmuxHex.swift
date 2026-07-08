import AppKit
import SwiftUI

/// `#RRGGBB` hex conversion for `Color`, used by the Workspace Colors
/// pickers.
public extension Color {
    /// Creates a color from a `#RRGGBB` (or `RRGGBB`) hex string, or
    /// returns `nil` when the string isn't a 6-digit hex color.
    init?(cmuxHex hex: String) {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let intVal = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((intVal >> 16) & 0xFF) / 255
        let g = Double((intVal >> 8) & 0xFF) / 255
        let b = Double(intVal & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// The color rendered as a `#RRGGBB` string in the sRGB color space.
    var cmuxHexString: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
