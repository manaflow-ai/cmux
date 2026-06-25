import AppKit
import SwiftUI

public extension Color {
    /// Parses a "RRGGBB" hex string into an sRGB color (falls back to white).
    init(sleepyHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }

    /// "RRGGBB" hex for persistence.
    var sleepyHex: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    /// Blend toward black / white for deriving shades from a custom color.
    func sleepyDarkened(_ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: .black) ?? base)
    }

    func sleepyLightened(_ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: .white) ?? base)
    }
}
