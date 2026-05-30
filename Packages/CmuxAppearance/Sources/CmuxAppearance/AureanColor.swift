import SwiftUI

/// A resolution-independent, testable color value used throughout the Aurean theme layer.
///
/// ``AureanColor`` stores straight (non-premultiplied) sRGB components in the `0...1`
/// range plus an alpha channel. It deliberately avoids wrapping `SwiftUI.Color` or
/// `NSColor` as its storage so that the whole theme layer can be unit-tested without
/// launching AppKit or a rendering context — tests assert on ``red``/``green``/``blue``/
/// ``alpha`` directly.
///
/// Convert to platform colors only at the view boundary via ``color`` or ``nsColor``.
///
/// ```swift
/// let sand = AureanColor(hex: "#C4C7CC")
/// Text("hello").foregroundStyle(sand.color)
/// ```
public struct AureanColor: Sendable, Hashable, Codable {
    /// The red component, in the sRGB `0...1` range.
    public let red: Double
    /// The green component, in the sRGB `0...1` range.
    public let green: Double
    /// The blue component, in the sRGB `0...1` range.
    public let blue: Double
    /// The opacity, in the `0...1` range, where `1` is fully opaque.
    public let alpha: Double

    /// Creates a color from straight sRGB components.
    ///
    /// - Parameters:
    ///   - red: Red component, clamped to `0...1`.
    ///   - green: Green component, clamped to `0...1`.
    ///   - blue: Blue component, clamped to `0...1`.
    ///   - alpha: Opacity, clamped to `0...1`. Defaults to `1` (opaque).
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    /// Creates a color from a `#RRGGBB` or `#RRGGBBAA` hex string.
    ///
    /// The leading `#` is optional and parsing is case-insensitive. An unparseable
    /// string yields opaque black, so this initializer never fails — the Aurean tokens
    /// are compile-time constants validated by tests, not user input.
    ///
    /// - Parameter hex: A 6- or 8-digit hex string, e.g. `"#161819"` or `"161819FF"`.
    public init(hex: String) {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        let digits = String(s)
        func byte(_ start: Int) -> Double {
            let lo = digits.index(digits.startIndex, offsetBy: start)
            let hi = digits.index(lo, offsetBy: 2)
            return Double(UInt8(digits[lo..<hi], radix: 16) ?? 0) / 255.0
        }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }) else {
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
            return
        }
        self.init(
            red: byte(0),
            green: byte(2),
            blue: byte(4),
            alpha: digits.count == 8 ? byte(6) : 1
        )
    }

    /// Returns a copy of this color with its alpha replaced by `opacity`.
    ///
    /// Used to project a solid token onto one of the Aurean φ-opacity stops
    /// (see ``AureanOpacity``) — depth in this theme is opacity, never shadow.
    ///
    /// - Parameter opacity: The new alpha, clamped to `0...1`.
    /// - Returns: A color identical in hue but at the requested opacity.
    public func opacity(_ opacity: Double) -> AureanColor {
        AureanColor(red: red, green: green, blue: blue, alpha: opacity)
    }

    /// The SwiftUI representation, in the sRGB color space.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// The AppKit representation, in the sRGB color space.
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
