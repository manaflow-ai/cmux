import AppKit
import SwiftUI

extension Color {
    /// Parses a "RRGGBB" hex string into an sRGB color (falls back to white).
    public init(sleepyHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }

    /// "RRGGBB" hex for persistence. Built from a fixed nibble table rather than
    /// `String(format:)`, which allocates per call (the PR #5347 regression
    /// class); harmless here but kept allocation-free on principle.
    public var sleepyHex: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let red = UInt8(clamping: Int((resolved.redComponent * 255).rounded()))
        let green = UInt8(clamping: Int((resolved.greenComponent * 255).rounded()))
        let blue = UInt8(clamping: Int((resolved.blueComponent * 255).rounded()))
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        var chars = [Character]()
        chars.reserveCapacity(6)
        for byte in [red, green, blue] {
            chars.append(digits[Int(byte >> 4)])
            chars.append(digits[Int(byte & 0x0F)])
        }
        return String(chars)
    }

    /// Blends toward black by `amount` (0...1) for deriving shades from a custom color.
    public func sleepyDarkened(_ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: .black) ?? base)
    }

    /// Blends toward white by `amount` (0...1) for deriving tints from a custom color.
    public func sleepyLightened(_ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: .white) ?? base)
    }
}
