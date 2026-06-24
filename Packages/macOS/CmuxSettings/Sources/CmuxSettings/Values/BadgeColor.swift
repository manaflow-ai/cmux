import Foundation

/// A resolved badge text color, expressed as sRGB components in `0...1`.
///
/// ``BadgeColor`` is intentionally UI-framework-free: it carries plain sRGB
/// component values so the ``CmuxSettings`` package stays free of SwiftUI and
/// AppKit. The terminal badge overlay (AppKit) and the Settings UI (SwiftUI)
/// each map a ``BadgeColor`` onto their own color type.
///
/// The badge color setting (`badge.color`) accepts either a `#RRGGBB` hex
/// string or one of the SwiftUI system color names exposed by ``names``
/// (case-insensitive). An empty or unrecognized string resolves to `nil`, which
/// the overlay treats as "follow the terminal's foreground color".
///
/// ```swift
/// BadgeColor(parsing: "green")     // BadgeColor(red: 0.20, green: 0.78, blue: 0.35)
/// BadgeColor(parsing: "#FF8800")   // BadgeColor(red: 1, green: 0.53, blue: 0)
/// BadgeColor(parsing: "")          // nil
/// ```
public struct BadgeColor: Equatable, Sendable {
    /// The red component in `0...1` (sRGB).
    public let red: Double
    /// The green component in `0...1` (sRGB).
    public let green: Double
    /// The blue component in `0...1` (sRGB).
    public let blue: Double

    /// Creates a badge color from explicit sRGB components.
    ///
    /// - Parameters:
    ///   - red: The red component in `0...1`.
    ///   - green: The green component in `0...1`.
    ///   - blue: The blue component in `0...1`.
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The canonical sRGB values for the supported SwiftUI system color names.
    ///
    /// Values mirror SwiftUI's standard (light) `Color` system palette so a
    /// `"green"` badge looks like SwiftUI's `Color.green`. Names are matched
    /// case-insensitively by ``init(parsing:)``.
    public static let namedColors: [String: BadgeColor] = [
        "red": BadgeColor(red: 1.00, green: 0.23, blue: 0.19),
        "orange": BadgeColor(red: 1.00, green: 0.58, blue: 0.00),
        "yellow": BadgeColor(red: 1.00, green: 0.80, blue: 0.00),
        "green": BadgeColor(red: 0.20, green: 0.78, blue: 0.35),
        "mint": BadgeColor(red: 0.00, green: 0.78, blue: 0.75),
        "teal": BadgeColor(red: 0.19, green: 0.69, blue: 0.78),
        "cyan": BadgeColor(red: 0.20, green: 0.68, blue: 0.90),
        "blue": BadgeColor(red: 0.00, green: 0.48, blue: 1.00),
        "indigo": BadgeColor(red: 0.35, green: 0.34, blue: 0.84),
        "purple": BadgeColor(red: 0.69, green: 0.32, blue: 0.87),
        "pink": BadgeColor(red: 1.00, green: 0.18, blue: 0.33),
        "brown": BadgeColor(red: 0.64, green: 0.52, blue: 0.37),
        "black": BadgeColor(red: 0.00, green: 0.00, blue: 0.00),
        "white": BadgeColor(red: 1.00, green: 1.00, blue: 1.00),
        "gray": BadgeColor(red: 0.56, green: 0.56, blue: 0.58),
        "grey": BadgeColor(red: 0.56, green: 0.56, blue: 0.58),
    ]

    /// The supported color names, sorted for stable presentation.
    ///
    /// Excludes the `"grey"` spelling alias so a picker lists each color once.
    public static var names: [String] {
        namedColors.keys.filter { $0 != "grey" }.sorted()
    }

    /// Parses a `badge.color` string into a ``BadgeColor``.
    ///
    /// Accepts a `#RRGGBB` hex string (with or without the leading `#`) or one
    /// of the case-insensitive ``names``. Surrounding whitespace is ignored.
    ///
    /// - Parameter raw: The stored `badge.color` string.
    /// - Returns: The resolved color, or `nil` when `raw` is empty or neither a
    ///   valid hex string nor a known name.
    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let named = BadgeColor.namedColors[trimmed.lowercased()] {
            self = named
            return
        }

        var cleaned = trimmed
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The color as an uppercased `#RRGGBB` hex string.
    ///
    /// Used by the Settings color well to write a canonical value back to
    /// `badge.color` after the user picks a color.
    public var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
