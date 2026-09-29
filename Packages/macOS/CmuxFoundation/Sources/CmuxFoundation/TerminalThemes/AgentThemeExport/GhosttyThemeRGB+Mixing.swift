import Foundation

extension GhosttyThemeRGB {
    /// The color as lowercase `#rrggbb`.
    public var hexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Blends this color toward `other` in sRGB.
    ///
    /// Agent themes use this for tints the terminal palette doesn't carry,
    /// such as a diff background that is the terminal background with a
    /// little green in it: `background.mixed(toward: green, amount: 0.22)`.
    /// - Parameters:
    ///   - other: The color to blend toward.
    ///   - amount: `0` returns this color, `1` returns `other`.
    /// - Returns: The blended color, each channel rounded to the nearest value.
    public func mixed(toward other: GhosttyThemeRGB, amount: Double) -> GhosttyThemeRGB {
        let clamped = min(max(amount, 0), 1)
        func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
            let value = Double(from) + (Double(to) - Double(from)) * clamped
            return UInt8(value.rounded())
        }
        return GhosttyThemeRGB(
            red: channel(red, other.red),
            green: channel(green, other.green),
            blue: channel(blue, other.blue)
        )
    }
}
