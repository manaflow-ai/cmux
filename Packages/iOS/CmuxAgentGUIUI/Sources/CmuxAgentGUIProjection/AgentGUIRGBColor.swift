import Foundation

/// A platform-neutral sRGB color used by the agent GUI theme projection.
public struct AgentGUIRGBColor: Hashable, Sendable {
    /// Red component in the closed `0...1` range.
    public let red: Double
    /// Green component in the closed `0...1` range.
    public let green: Double
    /// Blue component in the closed `0...1` range.
    public let blue: Double

    /// Creates a clamped sRGB color.
    /// - Parameters:
    ///   - red: Red component.
    ///   - green: Green component.
    ///   - blue: Blue component.
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Parses a six-digit terminal-theme color.
    /// - Parameter hex: A `#rrggbb` or `rrggbb` value.
    public init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let raw = Int(value, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((raw >> 16) & 0xff) / 255,
            green: Double((raw >> 8) & 0xff) / 255,
            blue: Double(raw & 0xff) / 255
        )
    }

    /// Mixes this color with another color directly in sRGB component space.
    /// - Parameters:
    ///   - other: The second color.
    ///   - ownWeight: This color's weight in the closed `0...1` range.
    /// - Returns: The weighted sRGB mix.
    public func mixed(with other: Self, ownWeight: Double) -> Self {
        let ownWeight = min(max(ownWeight, 0), 1)
        let otherWeight = 1 - ownWeight
        return Self(
            red: red * ownWeight + other.red * otherWeight,
            green: green * ownWeight + other.green * otherWeight,
            blue: blue * ownWeight + other.blue * otherWeight
        )
    }

    var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    private static func linearized(_ component: Double) -> Double {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    var hueAndSaturation: (hue: Double, saturation: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else {
            return (0, 0)
        }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 {
            hue += 360
        }
        return (hue, saturation)
    }
}
