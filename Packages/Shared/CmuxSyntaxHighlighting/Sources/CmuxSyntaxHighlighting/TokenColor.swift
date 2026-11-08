import Foundation

/// An sRGB color used by a ``TokenPalette``.
///
/// Hex is stored as six uppercase digits with no leading `#`.
public struct TokenColor: Sendable, Equatable, Hashable {
    /// Red channel, 0...255.
    public let red: UInt8
    /// Green channel, 0...255.
    public let green: UInt8
    /// Blue channel, 0...255.
    public let blue: UInt8

    /// Creates a color from 8-bit sRGB channels.
    ///
    /// - Parameters:
    ///   - red: Red channel, 0...255.
    ///   - green: Green channel, 0...255.
    ///   - blue: Blue channel, 0...255.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from `#RRGGBB` or `RRGGBB`.
    ///
    /// - Parameter hex: Six-digit hex, with or without a leading `#`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        digits = digits.uppercased()
        guard digits.count == 6,
              let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    /// Six-digit hex with a leading `#`, e.g. `#0091FF`.
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Six uppercase hex digits with no `#`. Used as a remapper lookup key.
    public var hexKey: String {
        String(format: "%02X%02X%02X", red, green, blue)
    }
}
